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
        {},
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
        {},
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
        {},
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
        {},
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        'Parent'
      )

      assert result.success?, "Expected dependent creation to succeed: #{result.data[:errors]}"
      dependent = result.data[:dependent]
      assert_equal '000-000-0042', dependent.phone
      assert_equal @guardian.phone, dependent.dependent_phone
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
        {},
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
          {},
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
          {},
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
        assert_equal 'Failed to create dependent', result.message
        assert_not_equal existing_dependent, service.dependent_user
      end
    end

    test 'paper guardian hard duplicate contact blocks before persistence without workflow side effects' do
      existing_guardian = create(
        :constituent,
        email: "existing-guardian-hard-#{SecureRandom.hex(4)}@example.com",
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
          nil,
          {
            first_name: 'New',
            last_name: 'Guardian',
            email: existing_guardian.email,
            phone: unique_service_phone,
            date_of_birth: '01/01/1980',
            physical_address_1: '101 Guardian Lane',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            communication_preference: 'email'
          },
          dependent_creation_attrs,
          'Parent'
        )

        assert_not result.success?
        assert_equal 'Failed to setup guardian', result.message
      end

      assert(service.errors.any? { |error| error.match?(/guardian.*already exists/i) })
      assert_not existing_guardian.reload.needs_duplicate_review
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
          {},
          dependent_creation_attrs(
            dependent_email: "new-dependent-hard-#{SecureRandom.hex(4)}@example.com",
            dependent_phone: existing_dependent.phone
          ),
          'Parent'
        )

        assert_not result.success?
        assert_equal 'Failed to create dependent', result.message
      end

      assert(service.errors.any? { |error| error.match?(/dependent.*already exists/i) })
      assert_not existing_dependent.reload.needs_duplicate_review
    end

    test 'paper guardian soft match opens duplicate review case through create service' do
      existing_guardian = create(
        :constituent,
        first_name: 'Soft',
        last_name: 'Guardian',
        date_of_birth: Date.new(1984, 2, 3),
        email: "existing-guardian-soft-#{SecureRandom.hex(4)}@example.com",
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

      assert_difference 'User.count', 2 do
        assert_difference 'GuardianRelationship.count', 1 do
          assert_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count'], 1 do
            assert_difference -> { Event.where(action: 'duplicate_review_case_opened').count }, 1 do
              result = service.process_guardian_scenario(
                nil,
                {
                  first_name: existing_guardian.first_name,
                  last_name: existing_guardian.last_name,
                  email: "new-guardian-soft-#{SecureRandom.hex(4)}@example.com",
                  phone: unique_service_phone,
                  date_of_birth: '02/03/1984',
                  physical_address_1: '303 Guardian Lane',
                  city: 'Baltimore',
                  state: 'MD',
                  zip_code: '21201',
                  communication_preference: 'email'
                },
                dependent_creation_attrs,
                'Parent'
              )

              assert result.success?, "Expected guardian/dependent creation to succeed: #{service.errors.inspect}"
            end
          end
        end
      end

      subject = service.guardian_user.reload
      assert subject.needs_duplicate_review

      duplicate_case = DuplicateReviewCase.find_by!(subject_user: subject)
      assert_equal 'paper_intake', duplicate_case.source
      assert_equal ['name_dob'], duplicate_case.metadata['reason_codes']
      assert_equal [existing_guardian.id], duplicate_case.duplicate_review_case_candidates.pluck(:candidate_user_id)

      event = Event.find_by!(action: 'duplicate_review_case_opened', auditable: subject)
      assert_equal @admin.id, event.user_id
    end

    test 'paper dependent soft match opens duplicate review case through create service' do
      existing_dependent = create(
        :constituent,
        first_name: 'Soft',
        last_name: 'Dependent',
        date_of_birth: Date.new(2014, 8, 9),
        email: "existing-dependent-soft-#{SecureRandom.hex(4)}@example.com",
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

      assert_difference 'User.count', 1 do
        assert_difference 'GuardianRelationship.count', 1 do
          assert_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count'], 1 do
            assert_difference -> { Event.where(action: 'duplicate_review_case_opened').count }, 1 do
              result = service.process_guardian_scenario(
                @guardian.id,
                {},
                dependent_creation_attrs(
                  first_name: existing_dependent.first_name,
                  last_name: existing_dependent.last_name,
                  date_of_birth: '08/09/2014'
                ),
                'Parent'
              )

              assert result.success?, "Expected dependent creation to succeed: #{service.errors.inspect}"
            end
          end
        end
      end

      subject = service.dependent_user.reload
      assert subject.needs_duplicate_review

      duplicate_case = DuplicateReviewCase.find_by!(subject_user: subject)
      assert_equal 'paper_intake', duplicate_case.source
      assert_equal ['name_dob'], duplicate_case.metadata['reason_codes']
      assert_equal [existing_dependent.id], duplicate_case.duplicate_review_case_candidates.pluck(:candidate_user_id)

      event = Event.find_by!(action: 'duplicate_review_case_opened', auditable: subject)
      assert_equal @admin.id, event.user_id
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
