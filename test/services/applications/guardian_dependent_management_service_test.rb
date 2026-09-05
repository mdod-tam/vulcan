# frozen_string_literal: true

require 'test_helper'

module Applications
  class GuardianDependentManagementServiceTest < ActiveSupport::TestCase
    setup do
      @guardian = create(:constituent, email: 'guardian@example.com', phone: '410-555-0100')
      @admin = create(:admin)
    end

    test 'process_guardian_scenario returns failure result when guardian information is missing' do
      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        nil,
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        'Parent'
      )

      assert_not result.success?
      assert_equal 'Failed to setup guardian', result.message
      assert_includes result.data[:errors], 'Guardian information missing'
      assert_includes service.errors, 'Guardian information missing'
    end

    test 'process_guardian_scenario returns failure result when guardian id is invalid' do
      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        -1,
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        'Parent'
      )

      assert_not result.success?
      assert_equal 'Failed to setup guardian', result.message
      assert_includes result.data[:errors], 'Guardian not found'
    end

    test 'process_guardian_scenario returns failure result when relationship type is missing' do
      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        @guardian.id,
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        nil
      )

      assert_not result.success?
      assert_equal 'Failed to create relationship', result.message
      assert(result.data[:errors].any? { |error| error.include?('Relationship type required') })
    end

    test 'guardian phone strategy creates unique synthetic primary phone' do
      SecureRandom
        .stubs(:random_number)
        .with(GuardianDependentManagementService::SYNTHETIC_PHONE_RANDOM_SPACE)
        .returns(42)

      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        @guardian.id,
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        'Parent'
      )

      assert result.success?, "Expected dependent creation to succeed: #{result.data[:errors]}"
      dependent = result.data[:dependent]
      assert_equal '000-000-0042', dependent.phone
      assert_equal @guardian.phone, dependent.dependent_phone
    end

    test 'guardian phone strategy reuses a preallocated synthetic primary phone' do
      User.expects(:exists_with_phone?).never
      service = GuardianDependentManagementService.new(
        {
          email_strategy: 'guardian',
          phone_strategy: 'guardian',
          address_strategy: 'dependent'
        },
        preallocated_synthetic_phone: '000-123-4567'
      )

      result = service.apply_contact_strategies_for(
        @guardian,
        { first_name: 'Child', last_name: 'User', phone: '' }
      )

      assert_equal '000-123-4567', result[:phone]
      assert_equal @guardian.phone, result[:dependent_phone]
    end

    test 'constructor-injected users create a guardian relationship without hidden instance mutation' do
      dependent = create(:constituent)
      service = GuardianDependentManagementService.new(
        {
          email_strategy: 'dependent',
          phone_strategy: 'dependent',
          address_strategy: 'dependent'
        },
        guardian_user: @guardian,
        dependent_user: dependent
      )

      assert_difference 'GuardianRelationship.count', 1 do
        assert service.create_guardian_relationship('Parent')
      end

      relationship = GuardianRelationship.order(:id).last
      assert_equal @guardian.id, relationship.guardian_id
      assert_equal dependent.id, relationship.dependent_id
    end

    test 'public relationship creation refuses a guardian retired by a merge' do
      dependent = create(:constituent)
      survivor = create(:constituent)
      stale_guardian = @guardian
      @guardian.update!(status: :inactive, merged_into_user: survivor, merged_at: Time.current)
      service = GuardianDependentManagementService.new(
        {},
        guardian_user: stale_guardian,
        dependent_user: dependent
      )

      assert_no_difference 'GuardianRelationship.count' do
        assert_not service.create_guardian_relationship('Parent')
      end
      assert_includes service.errors.join(' '), 'guardian must be an active constituent'
    end

    test 'public relationship creation refuses a dependent retired by a merge' do
      survivor = create(:constituent)
      dependent = create(:constituent)
      stale_dependent = dependent
      dependent.update!(status: :inactive, merged_into_user: survivor, merged_at: Time.current)
      service = GuardianDependentManagementService.new(
        {},
        guardian_user: @guardian,
        dependent_user: stale_dependent
      )

      assert_no_difference 'GuardianRelationship.count' do
        assert_not service.create_guardian_relationship('Parent')
      end
      assert_includes service.errors.join(' '), 'dependent must be an active constituent'
    end

    test 'guardian phone strategy skips occupied synthetic primary phone' do
      create(:constituent, phone: '000-000-0000')
      SecureRandom
        .stubs(:random_number)
        .with(GuardianDependentManagementService::SYNTHETIC_PHONE_RANDOM_SPACE)
        .returns(0, 1)

      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        @guardian.id,
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        'Parent'
      )

      assert result.success?, "Expected dependent creation to succeed: #{result.data[:errors]}"
      assert_equal '000-000-0001', result.data[:dependent].phone
    end

    test 'guardian phone strategy returns failure when synthetic phone attempts are exhausted' do
      create(:constituent, phone: '000-000-0000')
      SecureRandom
        .stubs(:random_number)
        .with(GuardianDependentManagementService::SYNTHETIC_PHONE_RANDOM_SPACE)
        .returns(*Array.new(GuardianDependentManagementService::SYNTHETIC_PHONE_MAX_ATTEMPTS, 0))

      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      assert_no_difference 'User.count' do
        result = service.process_guardian_scenario(
          @guardian.id,
          { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
          'Parent'
        )

        assert_not result.success?
        assert_equal 'Failed to apply contact strategies', result.message
        assert_includes result.data[:errors], 'Unable to generate unique synthetic dependent phone'
      end
    end

    test 'new dependent creation does not silently reuse existing user by submitted contact' do
      existing_dependent = create(
        :constituent,
        email: "existing-dependent-#{SecureRandom.hex(4)}@example.com",
        phone: "410-555-#{SecureRandom.random_number(9000) + 1000}"
      )

      service = GuardianDependentManagementService.new(
        email_strategy: 'dependent',
        phone_strategy: 'dependent',
        address_strategy: 'dependent'
      )

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        result = service.process_guardian_scenario(
          @guardian.id,
          {
            first_name: 'New',
            last_name: 'Dependent',
            dependent_email: existing_dependent.email,
            dependent_phone: "410-555-#{SecureRandom.random_number(9000) + 1000}",
            date_of_birth: '2015-01-01',
            hearing_disability: true
          },
          'Parent'
        )

        assert_not result.success?
        assert_equal 'Dependent identity review refused the write', result.message
        assert_not_equal existing_dependent, service.dependent_user
      end
    end

    test 'paper dependent hard duplicate contact blocks before persistence without workflow side effects' do
      existing_dependent = create(
        :constituent,
        email: "existing-dependent-hard-#{SecureRandom.hex(4)}@example.com",
        phone: unique_service_phone
      )

      service = GuardianDependentManagementService.new(
        {
          email_strategy: 'dependent',
          phone_strategy: 'dependent',
          address_strategy: 'dependent'
        },
        actor: @admin
      )

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'DuplicateReviewCase.count',
                            'DuplicateReviewCaseCandidate.count', 'Event.count'] do
        result = service.process_guardian_scenario(
          @guardian.id,
          dependent_creation_attrs(
            dependent_email: "new-dependent-hard-#{SecureRandom.hex(4)}@example.com",
            dependent_phone: existing_dependent.phone
          ),
          'Parent'
        )

        assert_not result.success?
        assert_equal 'Dependent identity review refused the write', result.message
      end

      assert(service.errors.any? { |error| error.match?(/dependent.*already exists/i) })
      assert_not existing_dependent.reload.needs_duplicate_review
    end

    test 'paper dependent soft match requires a signed override and opens no case' do
      existing_dependent = create(
        :constituent,
        first_name: 'Soft',
        last_name: 'Dependent',
        date_of_birth: Date.new(2014, 8, 9),
        email: "existing-dependent-soft-#{SecureRandom.hex(4)}@example.com",
        phone: unique_service_phone
      )

      attrs = dependent_creation_attrs(
        first_name: existing_dependent.first_name,
        last_name: existing_dependent.last_name,
        date_of_birth: '08/09/2014'
      )
      preview = PaperIdentityReview.new(
        constituent_params: attrs,
        contact_flag_params: {
          email_strategy: 'dependent', phone_strategy: 'dependent', address_strategy: 'dependent'
        },
        admin: @admin,
        context: :dependent,
        context_data: { guardian: @guardian, relationship_type: 'Parent' }
      ).call
      assert preview.needs_confirmation?

      service_for = lambda do |decision:, relationship_type: 'Parent'|
        GuardianDependentManagementService.new(
          {
            email_strategy: 'dependent',
            phone_strategy: 'dependent',
            address_strategy: 'dependent',
            relationship_type: relationship_type,
            identity_decision: decision
          },
          actor: @admin
        )
      end

      refused_writes = ['User.count', 'GuardianRelationship.count', 'Application.count',
                        'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count',
                        'Event.count', 'Notification.count']
      [{ decision: nil, relationship_type: 'Parent' },
       { decision: "#{preview.token}tampered", relationship_type: 'Parent' },
       { decision: preview.token, relationship_type: 'Legal Guardian' }].each do |attempt|
        assert_no_difference refused_writes do
          refused = service_for.call(**attempt)
          result = refused.process_guardian_scenario(@guardian.id, attrs, attempt[:relationship_type])
          assert_not result.success?, "expected #{attempt.inspect} to be refused"
        end
      end

      travel 31.minutes do
        assert_no_difference refused_writes do
          expired = service_for.call(decision: preview.token)
          result = expired.process_guardian_scenario(@guardian.id, attrs, 'Parent')
          assert_not result.success?, 'an expired dependent decision must be refused'
        end
      end

      service = service_for.call(decision: preview.token)

      assert_difference 'User.count', 1 do
        assert_difference 'GuardianRelationship.count', 1 do
          assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count'] do
            assert_difference -> { Event.where(action: 'paper_identity_no_match_confirmed').count }, 1 do
              result = service.process_guardian_scenario(@guardian.id, attrs, 'Parent')
              assert result.success?, "Expected dependent creation to succeed: #{service.errors.inspect}"
            end
          end
        end
      end

      subject = service.dependent_user.reload
      assert_not subject.needs_duplicate_review

      event = Event.find_by!(action: 'paper_identity_no_match_confirmed', auditable: subject)
      assert_equal @admin.id, event.user_id
      assert_equal 'paper_new_dependent', event.metadata['decision_context']
      assert_equal [existing_dependent.id], event.metadata['candidate_ids']
    end

    test 'new dependent own-contact strategies refuse blank email and phone independently' do
      base_params = {
        email_strategy: 'dependent', phone_strategy: 'dependent', address_strategy: 'guardian',
        relationship_type: 'Parent'
      }

      [{ dependent_email: '', dependent_phone: unique_service_phone },
       { dependent_email: "dependent-#{SecureRandom.hex(4)}@example.com", dependent_phone: '' }].each do |contacts|
        service = GuardianDependentManagementService.new(base_params, actor: @admin)
        attrs = dependent_creation_attrs.merge(contacts)

        assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                              'DuplicateReviewCase.count', 'Event.count', 'Notification.count'] do
          result = service.process_guardian_scenario(@guardian.id, attrs, 'Parent')
          assert_not result.success?
          assert_match(/enter the dependent's (email|phone)/i, service.errors.join(' '))
        end
      end
    end

    test 'new dependent guardian-contact strategies accept blank submitted contact' do
      service = GuardianDependentManagementService.new(
        {
          email_strategy: 'guardian', phone_strategy: 'guardian', address_strategy: 'guardian',
          relationship_type: 'Parent'
        },
        actor: @admin
      )
      attrs = dependent_creation_attrs.merge(dependent_email: '', dependent_phone: '')

      assert_difference 'User.count', 1 do
        assert_difference 'GuardianRelationship.count', 1 do
          result = service.process_guardian_scenario(@guardian.id, attrs, 'Parent')
          assert result.success?, service.errors.inspect
        end
      end

      assert_equal @guardian.email, service.dependent_user.dependent_email
      assert_equal @guardian.phone, service.dependent_user.dependent_phone
    end

    private

    def unique_service_phone
      "410-555-#{format('%04d', SecureRandom.random_number(9000) + 1000)}"
    end

    def dependent_creation_attrs(overrides = {})
      {
        first_name: 'Child',
        last_name: 'User',
        dependent_email: "dependent-#{SecureRandom.hex(4)}@example.com",
        dependent_phone: unique_service_phone,
        date_of_birth: '2015-01-01',
        hearing_disability: true,
        physical_address_1: '202 Dependent Lane',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201',
        communication_preference: 'email'
      }.merge(overrides)
    end
  end
end
