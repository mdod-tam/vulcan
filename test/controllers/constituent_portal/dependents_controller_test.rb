# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class DependentsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @guardian = create(:constituent)
      @dependent = create(:constituent)
      @guardian_relationship = GuardianRelationship.create!(
        guardian_user: @guardian,
        dependent_user: @dependent,
        relationship_type: 'Parent'
      )
      sign_in_for_controller_test(@guardian)
    end

    test 'should get new dependent page' do
      get new_constituent_portal_dependent_url # Assuming route helper: new_constituent_portal_dependent_path
      assert_response :success
    end

    test 'should create dependent and guardian relationship' do
      dependent_attributes = {
        first_name: 'Jane',
        last_name: 'Doe',
        date_of_birth: '2010-05-15',
        # Add other required User attributes for a dependent
        email: 'jane.doe.dependent@example.com', # Dependents might need unique emails or a strategy for this
        phone: '5555550011', # Similarly for phone
        hearing_disability: true # At least one disability required
      }
      guardian_relationship_attributes = {
        relationship_type: 'Parent'
      }

      assert_difference ['User.count', 'GuardianRelationship.count'], 1 do
        post constituent_portal_dependents_url, params: { # Assuming route helper: constituent_portal_dependents_path
          dependent: dependent_attributes,
          guardian_relationship: guardian_relationship_attributes
        }
      end

      new_dependent = User.find_by(email: 'jane.doe.dependent@example.com')
      assert(new_dependent, 'New dependent user was not created')
      assert_redirected_to constituent_portal_dashboard_url # Or wherever guardians manage dependents

      relationship = GuardianRelationship.find_by(guardian_user: @guardian, dependent_user: new_dependent)
      assert(relationship, 'GuardianRelationship was not created')
      assert_equal('Parent', relationship.relationship_type)

      assert_includes(@guardian.dependents, new_dependent)
    end

    test 'soft duplicate dependent creation opens duplicate review case' do
      existing_dependent = create(
        :constituent,
        first_name: 'Portal',
        last_name: 'Duplicate',
        date_of_birth: Date.new(2010, 5, 15),
        email: "portal-dependent-existing-#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      dependent_email = "portal-dependent-new-#{SecureRandom.hex(4)}@example.com"

      assert_difference ['User.count', 'GuardianRelationship.count', 'DuplicateReviewCase.count',
                         'DuplicateReviewCaseCandidate.count'], 1 do
        assert_difference -> { Event.where(action: 'duplicate_review_case_opened').count }, 1 do
          post constituent_portal_dependents_url, params: {
            dependent: {
              first_name: existing_dependent.first_name,
              last_name: existing_dependent.last_name,
              date_of_birth: '05/15/2010',
              email: dependent_email,
              phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
              hearing_disability: true
            },
            guardian_relationship: { relationship_type: 'Parent' }
          }
        end
      end

      new_dependent = User.find_by!(email: dependent_email)
      assert new_dependent.needs_duplicate_review
      assert_redirected_to constituent_portal_dashboard_url

      duplicate_case = DuplicateReviewCase.find_by!(subject_user: new_dependent)
      assert_equal 'portal_dependent', duplicate_case.source
      assert_equal ['name_dob'], duplicate_case.metadata['reason_codes']
      assert_equal 'portal_dependent', duplicate_case.metadata['intake_context']
      assert_equal [existing_dependent.id], duplicate_case.duplicate_review_case_candidates.pluck(:candidate_user_id)

      event = Event.find_by!(action: 'duplicate_review_case_opened', auditable: new_dependent)
      assert_equal @guardian.id, event.user_id
    end

    test 'review case failure rolls back the dependent and relationship without compensating destroy' do
      existing_dependent = create(
        :constituent,
        first_name: 'Rollback',
        last_name: 'Dependent',
        date_of_birth: Date.new(2010, 5, 15),
        email: "portal-dependent-existing-#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      dependent_email = "portal-dependent-rollback-#{SecureRandom.hex(4)}@example.com"
      DuplicateReviewCases::CreateService.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'case creation failed', data: {})
      )
      Rails.logger.stubs(:warn)

      # Counts alone are not a negative sensor for the former compensation path:
      # User#destroy cascades both guardian relationship associations, so that path also
      # finishes at zero rows. Keep this assertion to prove rollback replaced compensation.
      User.any_instance.expects(:destroy).never

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'DuplicateReviewCase.count',
                            'DuplicateReviewCaseCandidate.count'] do
        assert_no_difference -> { Event.where(action: 'duplicate_review_case_opened').count } do
          post constituent_portal_dependents_url, params: {
            dependent: {
              first_name: existing_dependent.first_name,
              last_name: existing_dependent.last_name,
              date_of_birth: '05/15/2010',
              email: dependent_email,
              phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
              hearing_disability: true
            },
            guardian_relationship: { relationship_type: 'Parent' }
          }
        end
      end

      assert_response :unprocessable_content
      assert_select "form[action='#{constituent_portal_dependents_path}'][method='post']"
      assert_not User.exists?(email: dependent_email)
    end

    # Rollback restores the attempted dependent to a new record but keeps the synthetic contact
    # the guardian strategy wrote into it. Re-rendering that object would show internal
    # placeholders as if the guardian had typed them, uncheck "use my email/phone", and let an
    # unchanged retry store those placeholders as dependent-owned contact.
    test 'guardian-strategy failure re-renders the submitted contact choice, never internal placeholders' do
      existing_dependent = create(
        :constituent,
        first_name: 'Placeholder',
        last_name: 'Leak',
        date_of_birth: Date.new(2010, 5, 15),
        email: "portal-dependent-leak-#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      DuplicateReviewCases::CreateService.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'case creation failed', data: {})
      )
      Rails.logger.stubs(:warn)

      post constituent_portal_dependents_url, params: {
        # The guardian contact strategy: blank dependent contact plus the "use mine" checkboxes.
        dependent: {
          first_name: existing_dependent.first_name,
          last_name: existing_dependent.last_name,
          date_of_birth: '05/15/2010',
          email: '',
          phone: '',
          hearing_disability: true
        },
        use_guardian_email: '1',
        use_guardian_phone: '1',
        guardian_relationship: { relationship_type: 'Parent' }
      }

      assert_response :unprocessable_content
      assert_no_match(/@system\.matvulcan\.local/, response.body,
                      'the synthetic primary email must never be rendered back into the form')
      assert_no_match(/000-\d{3}-\d{4}/, response.body,
                      'the synthetic primary phone must never be rendered back into the form')
      assert_select 'input#use_guardian_email_checkbox[checked]', 1,
                    'the guardian email choice must survive the failed attempt'
      assert_select 'input#use_guardian_phone_checkbox[checked]', 1,
                    'the guardian phone choice must survive the failed attempt'
    end

    # The failure re-render must show what the *locked* pass decided, not re-derive it from the
    # pre-lock current_user. matches_guardian_contact? is the one strategy branch that reads the
    # guardian's own contact, so a guardian contact change landing inside the lock window makes the
    # same submitted value match under one instance and not the other.
    #
    # The change is injected just before the lock returns rather than through the concurrency
    # harness: the failure has to be forced by stubbing CreateService, and mocha is not thread-safe,
    # so stubbing across the harness's threads would be flaky. This drives the real controller
    # single-threaded and reproduces the same stale-instance divergence deterministically.
    test 'a failed attempt renders the contact choice the locked pass applied, not a re-derivation' do
      existing_dependent = create(
        :constituent,
        first_name: 'Locked', last_name: 'Choice', date_of_birth: Date.new(2010, 5, 15),
        email: "portal-dependent-locked-#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      guardian_old_email = @guardian.email
      rotated_email = "rotated-guardian-#{SecureRandom.hex(4)}@example.com"

      # Submitted dependent email equals the guardian's CURRENT email, so the pre-lock derivation
      # says "guardian". The lock then observes rotated contact, so the locked pass says
      # "dependent" -- the divergence this guards.
      rotate = lambda do
        @guardian.update_columns(email: rotated_email)
        rotate = nil
      end
      original = User.method(:lock_for_merge_integrity!)
      User.define_singleton_method(:lock_for_merge_integrity!) do |*args|
        rotate&.call
        original.call(*args)
      end

      DuplicateReviewCases::CreateService.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'case creation failed', data: {})
      )
      Rails.logger.stubs(:warn)

      post constituent_portal_dependents_url, params: {
        dependent: {
          first_name: existing_dependent.first_name, last_name: existing_dependent.last_name,
          date_of_birth: '05/15/2010', email: guardian_old_email,
          phone: "555-#{rand(100..999)}-#{rand(1000..9999)}", hearing_disability: true
        },
        guardian_relationship: { relationship_type: 'Parent' }
      }

      assert_response :unprocessable_content
      assert_select 'input#use_guardian_email_checkbox[checked]', 0,
                    'the locked pass chose dependent email routing, so the form must not offer guardian routing'
    ensure
      User.singleton_class.remove_method(:lock_for_merge_integrity!)
    end

    # A guardian may type dependent contact and *then* check "use my email/phone". The portal form
    # declares no guardian-contact JS targets, so copyGuardianEmail/copyGuardianPhone return early
    # and the typed value survives in params. If the failed re-render infers the checkbox from
    # contact blankness, both boxes come back unchecked and an unchanged retry silently stores
    # dependent-owned contact -- routing this dependent's communications to the dependent rather
    # than the guardian.
    test 'a failed attempt preserves the guardian contact choice made over typed contact' do
      # A soft-match candidate, so creation reaches the review-case step that is forced to fail.
      existing_dependent = create(
        :constituent,
        first_name: 'Typed',
        last_name: 'Contact',
        date_of_birth: Date.new(2010, 5, 15),
        email: "portal-dependent-typed-#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      typed_email = "typed-dependent-#{SecureRandom.hex(4)}@example.com"
      typed_phone = '555-987-6543'
      submitted = {
        dependent: {
          first_name: existing_dependent.first_name, last_name: existing_dependent.last_name,
          date_of_birth: '05/15/2010',
          email: typed_email, phone: typed_phone, hearing_disability: true
        },
        use_guardian_email: '1',
        use_guardian_phone: '1',
        guardian_relationship: { relationship_type: 'Parent' }
      }

      DuplicateReviewCases::CreateService.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'case creation failed', data: {})
      )
      Rails.logger.stubs(:warn)
      post constituent_portal_dependents_url, params: submitted

      assert_response :unprocessable_content
      assert_select 'input#use_guardian_email_checkbox[checked]', 1,
                    'the guardian email choice must survive even though contact was typed'
      assert_select 'input#use_guardian_phone_checkbox[checked]', 1,
                    'the guardian phone choice must survive even though contact was typed'

      # Retry exactly what the re-rendered form now submits, unchanged.
      DuplicateReviewCases::CreateService.any_instance.unstub(:call)
      post constituent_portal_dependents_url, params: submitted

      dependent = GuardianRelationship.where(guardian_id: @guardian.id).order(:id).last.dependent_user
      assert_equal 'Typed', dependent.first_name
      assert_equal @guardian.email, dependent.effective_email,
                   'communications must still route to the guardian after the failed attempt'
      assert_equal User.normalize_phone(@guardian.phone), User.normalize_phone(dependent.effective_phone),
                   'phone communications must still route to the guardian after the failed attempt'
      assert_not_equal typed_email, dependent.effective_email
    end

    # The participant set is resolved by duplicate detection and locked afterwards.
    # lock_for_merge_integrity! refuses a partial set, which is correct, but a candidate deleted
    # in that window is an ordinary concurrent condition and must not surface as a 500.
    test 'a candidate deleted before the lock fails closed with the ordinary retry response' do
      existing_dependent = create(
        :constituent,
        first_name: 'Vanishing',
        last_name: 'Candidate',
        date_of_birth: Date.new(2010, 5, 15),
        email: "portal-dependent-vanish-#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      dependent_email = "portal-dependent-vanish-new-#{SecureRandom.hex(4)}@example.com"

      # Delete the matched candidate after detection resolves it but before the lock is taken.
      User.stubs(:lock_for_merge_integrity!).with do |*|
        User.where(id: existing_dependent.id).delete_all
        true
      end.raises(ActiveRecord::RecordNotFound)

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'DuplicateReviewCase.count'] do
        post constituent_portal_dependents_url, params: {
          dependent: {
            first_name: 'Vanishing',
            last_name: 'Candidate',
            date_of_birth: '05/15/2010',
            email: dependent_email,
            phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
            hearing_disability: true
          },
          guardian_relationship: { relationship_type: 'Parent' }
        }
      end

      assert_response :unprocessable_content
      assert_select "form[action='#{constituent_portal_dependents_path}'][method='post']"
      assert_not User.exists?(email: dependent_email)
    end

    test 'soft-match creation locks the lower-id candidate and guardian together in ascending order before writing' do
      existing_dependent = create(
        :constituent,
        first_name: 'Ordered',
        last_name: 'Candidate',
        date_of_birth: Date.new(2010, 5, 15),
        email: "ordered-candidate-#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      later_guardian = create(:constituent)
      assert_operator existing_dependent.id, :<, later_guardian.id

      sign_out
      sign_in_for_controller_test(later_guardian)

      user_lock_queries = []
      subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
        sql = payload[:sql]
        next unless sql.include?('"users"') && sql.include?('FOR UPDATE')

        user_lock_queries << {
          sql: sql,
          binds: payload[:binds].map(&:value_for_database)
        }
      end

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        post constituent_portal_dependents_url, params: {
          dependent: {
            first_name: existing_dependent.first_name,
            last_name: existing_dependent.last_name,
            date_of_birth: '05/15/2010',
            email: "ordered-subject-#{SecureRandom.hex(4)}@example.com",
            phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
            hearing_disability: true
          },
          guardian_relationship: { relationship_type: 'Parent' }
        }
      end

      first_user_lock = user_lock_queries.first
      assert first_user_lock, 'expected a User FOR UPDATE query before dependent persistence'
      assert_equal [existing_dependent.id, later_guardian.id], first_user_lock[:binds].sort
      assert_match(/ORDER BY "users"\."id" ASC FOR UPDATE\z/, first_user_lock[:sql])
      assert_redirected_to constituent_portal_dashboard_url
    end

    test 'should create dependent with MM/DD/YYYY date of birth' do
      dependent_attributes = {
        first_name: 'Date',
        last_name: 'Dependent',
        date_of_birth: '05/15/2010',
        email: 'date.dependent@example.com',
        phone: '5555551011',
        hearing_disability: true
      }

      assert_difference ['User.count', 'GuardianRelationship.count'], 1 do
        post constituent_portal_dependents_url, params: {
          dependent: dependent_attributes,
          guardian_relationship: { relationship_type: 'Parent' }
        }
      end

      new_dependent = User.find_by!(email: 'date.dependent@example.com')
      assert_equal Date.new(2010, 5, 15), new_dependent.date_of_birth
      assert_redirected_to constituent_portal_dashboard_url
    end

    test 'should reject dependent with malformed text date of birth' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(%r{Date of birth must be in MM/DD/YYYY format})).twice

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post constituent_portal_dependents_url, params: {
          dependent: {
            first_name: 'Bad',
            last_name: 'Date',
            date_of_birth: 'May 15 2010',
            email: 'bad.date.dependent@example.com',
            phone: '5555551012',
            hearing_disability: true
          },
          guardian_relationship: { relationship_type: 'Parent' }
        }
      end

      assert_response :unprocessable_content
      assert_match(%r{Date of birth must be in MM/DD/YYYY format}, response.body)
    end

    test 'should create dependent with guardian email fallback when dependent email is blank' do
      dependent_attributes = {
        first_name: 'Fallback',
        last_name: 'Dependent',
        date_of_birth: '2010-05-15',
        email: '',
        phone: '',
        hearing_disability: true
      }

      assert_difference ['User.count', 'GuardianRelationship.count'], 1 do
        post constituent_portal_dependents_url, params: {
          dependent: dependent_attributes,
          guardian_relationship: { relationship_type: 'Parent' },
          use_guardian_email: '1',
          use_guardian_phone: '1'
        }
      end

      new_dependent = @guardian.dependents.order(created_at: :desc).first
      assert_match(/\Adependent-.*@system\.matvulcan\.local\z/, new_dependent.email)
      assert_equal @guardian.email, new_dependent.dependent_email
      assert_redirected_to constituent_portal_dashboard_url
    end

    test 'should render create form when guardian phone synthetic generation fails' do
      create(:constituent, phone: '000-000-0000')
      SecureRandom
        .stubs(:random_number)
        .with(Applications::GuardianDependentManagementService::SYNTHETIC_PHONE_RANDOM_SPACE)
        .returns(*Array.new(Applications::GuardianDependentManagementService::SYNTHETIC_PHONE_MAX_ATTEMPTS, 0))

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post constituent_portal_dependents_url, params: {
          dependent: {
            first_name: 'Fallback',
            last_name: 'Dependent',
            date_of_birth: '2010-05-15',
            email: '',
            phone: '',
            hearing_disability: true
          },
          guardian_relationship: { relationship_type: 'Parent' },
          use_guardian_email: '1',
          use_guardian_phone: '1'
        }
      end

      assert_response :unprocessable_content
      assert_match(/Unable to generate unique synthetic dependent phone/, response.body)
    end

    test 'should not create dependent if attributes are invalid' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/Failed to create dependent user:/)).once
      Rails.logger.expects(:error).with(regexp_matches(/\[TEST_VALIDATION\] Failed to create dependent:/)).once

      dependent_attributes = { first_name: '' } # Invalid
      guardian_relationship_attributes = { relationship_type: 'Parent' }

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post constituent_portal_dependents_url, params: {
          dependent: dependent_attributes,
          guardian_relationship: guardian_relationship_attributes
        }
      end
      assert_response :unprocessable_content
      # We're expecting this error to be displayed in the form
      # Just check response status is correct (422) since the form rendering is tested elsewhere
    end

    test 'should require at least one disability to be selected when created through portal' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/Failed to create dependent user: Failed to create user: At least one disability must be selected\./)).once
      Rails.logger.expects(:error).with(regexp_matches(/\[TEST_VALIDATION\] Failed to create dependent: Failed to create user: At least one disability must be selected\./)).once

      dependent_attributes = {
        first_name: 'Jane',
        last_name: 'Doe',
        date_of_birth: '2010-05-15',
        email: 'jane.nodisability@example.com',
        phone: '5555550022'
        # No disabilities specified - they default to false
      }
      guardian_relationship_attributes = {
        relationship_type: 'Parent'
      }

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post constituent_portal_dependents_url, params: {
          dependent: dependent_attributes,
          guardian_relationship: guardian_relationship_attributes
        }
      end

      assert_response :unprocessable_content
      assert_match(/disability must be selected/i, response.body)
    end

    test 'should create dependent when at least one disability is selected' do
      dependent_attributes = {
        first_name: 'Jane',
        last_name: 'Doe',
        date_of_birth: '2010-05-15',
        email: 'jane.withdisability@example.com',
        phone: '5555550033',
        hearing_disability: true, # At least one disability selected
        vision_disability: false,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false
      }
      guardian_relationship_attributes = {
        relationship_type: 'Parent'
      }

      assert_difference ['User.count', 'GuardianRelationship.count'], 1 do
        post constituent_portal_dependents_url, params: {
          dependent: dependent_attributes,
          guardian_relationship: guardian_relationship_attributes
        }
      end

      assert_redirected_to constituent_portal_dashboard_url
      new_dependent = User.find_by(email: 'jane.withdisability@example.com')
      assert new_dependent.hearing_disability
    end

    # Bug fix verification test - Bugs #1, #2, #3
    test 'portal always creates NEW dependent with skip_user_lookup flag' do
      # This test verifies that portal uses skip_user_lookup: true
      # which always creates NEW users instead of finding existing ones
      dependent_attributes = {
        first_name: 'New',
        last_name: 'Dependent',
        date_of_birth: '2010-05-15',
        email: 'new.dependent.portal@example.com',
        phone: '5555559999',
        hearing_disability: true # Required for portal dependents
      }
      guardian_relationship_attributes = {
        relationship_type: 'Parent'
      }

      # Should create a new user
      assert_difference 'User.count', 1 do
        assert_difference 'GuardianRelationship.count', 1 do
          post constituent_portal_dependents_url, params: {
            dependent: dependent_attributes,
            guardian_relationship: guardian_relationship_attributes
          }
        end
      end

      # Verify the dependent was created correctly
      new_dependent = @guardian.dependents.order(created_at: :desc).first
      assert_not_nil new_dependent, 'No dependent was created'
      assert_equal 'New', new_dependent.first_name
      assert_equal 'Dependent', new_dependent.last_name
      assert_equal 'new.dependent.portal@example.com', new_dependent.email
    end

    test 'should destroy dependent and guardian relationship' do
      dependent_to_delete = create(:constituent, email: 'delete.me@example.com', phone: '5555550012')
      GuardianRelationship.create!(guardian_user: @guardian, dependent_user: dependent_to_delete, relationship_type: 'Ward')

      assert_difference 'GuardianRelationship.count', -1 do
        # Depending on implementation, destroying the User might cascade or relationship is destroyed directly
        # For this test, let's assume we destroy the relationship, and potentially the dependent user if they have no other guardians/apps
        # Or, if the route is for destroying the relationship:
        delete constituent_portal_dependent_url(dependent_to_delete) # Assuming route like dependent_path(dependent_to_delete)
      end

      # If dependent user should also be deleted if they have no other ties:
      # assert_raises(ActiveRecord::RecordNotFound) do
      #   User.find(dependent_to_delete.id)
      # end
      assert_empty(@guardian.dependents.where(id: dependent_to_delete.id))
      assert_redirected_to constituent_portal_dashboard_url # Or dependent management page
    end

    test 'should get show' do
      get constituent_portal_dependent_path(@dependent)
      assert_response :success
      assert_select 'h1', @dependent.full_name
    end

    test 'should get edit' do
      get edit_constituent_portal_dependent_path(@dependent)
      assert_response :success
      assert_select 'h1', "Edit #{@dependent.full_name}"
    end

    test 'should update dependent profile and log guardian change' do
      assert_difference('Event.count', 1) do
        patch constituent_portal_dependent_path(@dependent), params: {
          dependent: {
            first_name: 'Updated Dependent',
            last_name: 'New Last Name',
            email: 'updated.dependent@example.com'
          }
        }
      end

      assert_redirected_to constituent_portal_dashboard_path
      assert_equal 'Dependent was successfully updated.', flash[:notice]

      # Verify dependent was updated
      @dependent.reload
      assert_equal 'Updated Dependent', @dependent.first_name
      assert_equal 'New Last Name', @dependent.last_name
      assert_equal 'updated.dependent@example.com', @dependent.email

      # Verify audit log was created correctly
      event = Event.last
      assert_equal 'profile_updated_by_guardian', event.action
      assert_equal @guardian.id, event.user_id # Actor is the guardian
      assert_equal @dependent.id, event.metadata['user_id'] # Target is the dependent
      assert_equal @guardian.id, event.metadata['updated_by']

      # Verify changes are recorded
      changes = event.metadata['changes']
      assert_equal 'Updated Dependent', changes['first_name']['new']
      assert_equal 'New Last Name', changes['last_name']['new']
      assert_equal 'updated.dependent@example.com', changes['email']['new']
    end

    test 'should update dependent when submitted contact matches guardian contact' do
      patch constituent_portal_dependent_path(@dependent), params: {
        dependent: {
          first_name: 'Shared Contact',
          email: @guardian.email,
          phone: @guardian.phone
        }
      }

      assert_redirected_to constituent_portal_dashboard_path
      assert_equal 'Dependent was successfully updated.', flash[:notice]

      @dependent.reload
      assert_equal 'Shared Contact', @dependent.first_name
      assert_match(/\Adependent-.*@system\.matvulcan\.local\z/, @dependent.email)
      assert_equal @guardian.email, @dependent.dependent_email
      assert_equal @guardian.phone, @dependent.dependent_phone
    end

    test 'should preserve contact fields on partial update without submitted email or phone' do
      original_email = @dependent.email
      original_phone = @dependent.phone
      original_dependent_email = @dependent.dependent_email
      original_dependent_phone = @dependent.dependent_phone

      patch constituent_portal_dependent_path(@dependent), params: {
        dependent: {
          first_name: 'Test Update'
        }
      }

      assert_redirected_to constituent_portal_dashboard_path
      assert_equal 'Dependent was successfully updated.', flash[:notice]

      @dependent.reload
      assert_equal 'Test Update', @dependent.first_name
      assert_equal original_email, @dependent.email
      assert_equal original_phone, @dependent.phone
      assert_equal original_dependent_email, @dependent.dependent_email
      assert_equal original_dependent_phone, @dependent.dependent_phone
    end

    test 'should preserve phone on partial update when only email is submitted' do
      original_phone = @dependent.phone
      original_dependent_phone = @dependent.dependent_phone
      new_email = 'only.email.updated@example.com'

      patch constituent_portal_dependent_path(@dependent), params: {
        dependent: {
          email: new_email
        }
      }

      assert_redirected_to constituent_portal_dashboard_path

      @dependent.reload
      assert_equal new_email, @dependent.email
      assert_equal new_email, @dependent.dependent_email
      assert_equal original_phone, @dependent.phone
      assert_equal original_dependent_phone, @dependent.dependent_phone
    end

    test 'should set Current.user before update' do
      # Verify Current.user is set during the request
      DependentsController.any_instance.expects(:set_current_user).once

      patch constituent_portal_dependent_path(@dependent), params: {
        dependent: {
          first_name: 'Test Update'
        }
      }
    end

    test 'should show recent changes on dependent show page' do
      # Create some profile change events
      Event.create!(
        user: @guardian,
        action: 'profile_updated_by_guardian',
        metadata: {
          user_id: @dependent.id,
          changes: {
            'first_name' => { 'old' => 'Old Name', 'new' => 'New Name' },
            'email' => { 'old' => 'old@example.com', 'new' => 'new@example.com' }
          },
          updated_by: @guardian.id,
          timestamp: 1.day.ago.iso8601
        },
        created_at: 1.day.ago
      )

      get constituent_portal_dependent_path(@dependent)
      assert_response :success

      # Check that recent changes section is displayed
      assert_select '.bg-white', text: /Recent Changes/i
      assert_select 'span', text: @guardian.full_name
      assert_select 'span', text: /First name/i
      assert_select 'span.text-red-600', text: 'Old Name'
      assert_select 'span.text-green-600', text: 'New Name'
    end

    test 'should show recent changes on dependent edit page' do
      # Create some profile change events
      Event.create!(
        user: @guardian,
        action: 'profile_updated_by_guardian',
        metadata: {
          user_id: @dependent.id,
          changes: {
            'phone' => { 'old' => '555-123-4567', 'new' => '555-987-6543' }
          },
          updated_by: @guardian.id,
          timestamp: 2.hours.ago.iso8601
        },
        created_at: 2.hours.ago
      )

      get edit_constituent_portal_dependent_path(@dependent)
      assert_response :success

      # Check that recent changes section is displayed
      assert_select '.bg-white', text: /Recent Changes/i
      assert_select 'span', text: /Phone/i
      assert_select 'span.text-red-600', text: '555-123-4567'
      assert_select 'span.text-green-600', text: '555-987-6543'
    end

    test 'should not allow non-guardian to access dependent' do
      other_user = create(:constituent)
      sign_out
      sign_in_for_controller_test(other_user)

      get constituent_portal_dependent_path(@dependent)
      assert_redirected_to constituent_portal_dashboard_path
      assert_equal 'Dependent not found.', flash[:alert]
    end

    test 'should not allow non-guardian to update dependent' do
      other_user = create(:constituent)
      sign_out
      sign_in_for_controller_test(other_user)

      assert_no_difference('Event.count') do
        patch constituent_portal_dependent_path(@dependent), params: {
          dependent: {
            first_name: 'Should Not Update'
          }
        }
      end

      assert_redirected_to constituent_portal_dashboard_path
      assert_equal 'Dependent not found.', flash[:alert]

      # Verify dependent was not updated
      @dependent.reload
      assert_not_equal 'Should Not Update', @dependent.first_name
    end

    test 'should handle validation errors without logging event' do
      assert_no_difference('Event.count') do
        patch constituent_portal_dependent_path(@dependent), params: {
          dependent: {
            first_name: '', # Invalid - required field
            email: 'invalid-email' # Invalid format
          }
        }
      end

      assert_response :unprocessable_content
    end

    test 'should redirect to application if application_id param present' do
      application = create(:application, user: @dependent, managing_guardian: @guardian)

      patch constituent_portal_dependent_path(@dependent), params: {
        application_id: application.id,
        dependent: {
          first_name: 'Updated for App'
        }
      }

      assert_redirected_to constituent_portal_application_path(application)
      assert_equal 'Dependent was successfully updated.', flash[:notice]
    end

    %i[inactive suspended].each do |status|
      test "guardian can edit an unmerged #{status} dependent" do
        @dependent.update!(status: status)

        patch constituent_portal_dependent_path(@dependent), params: {
          dependent: { first_name: 'Still Editable' }
        }

        assert_redirected_to constituent_portal_dashboard_path
        assert_equal 'Still Editable', @dependent.reload.first_name
        assert_not @dependent.merged?
      end
    end

    test 'should only allow permitted parameters' do
      # Try to update a field that shouldn't be allowed
      patch constituent_portal_dependent_path(@dependent), params: {
        dependent: {
          first_name: 'Allowed Update',
          type: 'Users::Administrator', # Should not be allowed
          status: 'suspended' # Should not be allowed
        }
      }

      @dependent.reload
      assert_equal 'Allowed Update', @dependent.first_name
      assert_not_equal 'Users::Administrator', @dependent.type
      assert_not_equal 'suspended', @dependent.status
    end

    test 'should require constituent user' do
      admin = create(:admin)
      sign_out
      sign_in_for_controller_test(admin)

      get constituent_portal_dependent_path(@dependent)
      assert_redirected_to root_path
      assert_equal 'Access denied. Constituent-only area.', flash[:alert]
    end

    # --- Request-replay idempotency -------------------------------------------------------------
    #
    # A replay is the *same request* arriving twice, so these tests resend a byte-for-byte identical
    # body. That matters: a real replay carries the same email and phone as the record it already
    # created, which exact-contact detection sees as a hard block. Varying the contact details per
    # call would sidestep that entirely and test nothing.

    test 'replaying an identical request creates exactly one dependent' do
      key = SecureRandom.hex(16)
      body = dependent_body

      assert_difference ['User.count', 'GuardianRelationship.count'], 1 do
        2.times { post_dependent(body, portal_creation_key: key) }
      end

      assert_redirected_to constituent_portal_dashboard_url
      assert_match(/already added/i, flash[:notice])
    end

    # The exact-contact hard block runs before the lock and would otherwise refuse the replay with a
    # support-contact dead end, never consulting the key.
    test 'a replay is not refused by exact-contact duplicate detection' do
      key = SecureRandom.hex(16)
      body = dependent_body
      post_dependent(body, portal_creation_key: key)

      post_dependent(body, portal_creation_key: key)

      assert_nil flash[:alert]
      assert_match(/already added/i, flash[:notice])
    end

    # The fingerprint must depend on submitted intent alone. Re-deriving the contact strategy by
    # comparing submitted contact against the guardian's *current* email or phone would make it a
    # function of mutable state: the guardian edits their own contact, and a byte-identical replay
    # hashes differently and is wrongly refused as stale.
    test 'a replay still resolves after the guardian changes their own contact' do
      key = SecureRandom.hex(16)
      # Submitted contact that *matches* the guardian's current contact is the case that exposes the
      # defect: a strategy re-derived by comparison reads this as 'guardian' now and 'dependent'
      # after the guardian edits their own record, so the same bytes would hash two ways.
      body = dependent_body(email: @guardian.email, phone: @guardian.phone)
      post_dependent(body, portal_creation_key: key)

      @guardian.update!(email: "moved-#{SecureRandom.hex(3)}@example.com", phone: '555-555-7788')

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post_dependent(body, portal_creation_key: key)
      end
      assert_match(/already added/i, flash[:notice])
      assert_nil flash[:alert]
    end

    test 'a replay writes nothing at all' do
      key = SecureRandom.hex(16)
      body = dependent_body
      post_dependent(body, portal_creation_key: key)

      assert_no_difference ['User.count', 'GuardianRelationship.count',
                            'DuplicateReviewCase.count', 'Event.count', 'Notification.count'] do
        post_dependent(body, portal_creation_key: key)
      end
    end

    # A replay key means "repeat this creation operation", so the key is spent against everything
    # semantically submitted -- not just who the dependent is. Each of these would otherwise be
    # reported as "already added" while the change was silently discarded.
    {
      'a changed first name' => { first_name: 'Robert' },
      'a changed date of birth' => { date_of_birth: '2012-03-03' },
      'a changed dependent email' => { email: 'someone.else@example.com' },
      'a changed dependent phone' => { phone: '5555559999' },
      'a changed phone type' => { phone_type: 'videophone' },
      'a changed disability selection' => { vision_disability: true },
      'a changed newsletter choice' => { newsletter_signup: true }
    }.each do |description, change|
      test "the same key with #{description} is refused without mutation" do
        key = SecureRandom.hex(16)
        body = dependent_body(phone_type: 'voice', newsletter_signup: false)
        post_dependent(body, portal_creation_key: key)

        assert_no_difference ['User.count', 'GuardianRelationship.count'] do
          post_dependent(body.merge(change), portal_creation_key: key)
        end
        assert_match(/out of date/i, flash[:alert])
      end
    end

    test 'the same key with a changed relationship type is refused without mutation' do
      key = SecureRandom.hex(16)
      body = dependent_body
      post_dependent(body, portal_creation_key: key)

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post_dependent(body, portal_creation_key: key, relationship_type: 'Legal Guardian')
      end
      assert_match(/out of date/i, flash[:alert])
    end

    # The fingerprint is stored beside the key, and the two are meaningless apart.
    test 'a successful creation stores the key and its fingerprint together' do
      key = SecureRandom.hex(16)
      post_dependent(dependent_body, portal_creation_key: key)

      relationship = GuardianRelationship.find_by!(guardian_id: @guardian.id, portal_creation_key: key)
      assert relationship.portal_creation_fingerprint.present?
      assert_match(/\Av1:[a-f0-9]{64}\z/, relationship.portal_creation_fingerprint,
                   'the fingerprint must be versioned and keyed, not a bare digest')
    end

    # A creation without a key stores neither half, satisfying the check constraint.
    test 'a creation without a key stores neither half of the replay pair' do
      post_dependent(dependent_body)

      relationship = GuardianRelationship.where(guardian_id: @guardian.id).order(:id).last
      assert_nil relationship.portal_creation_key
      assert_nil relationship.portal_creation_fingerprint
    end

    # Replay identity is (authenticated guardian, request key), so a key is one guardian's request
    # namespace rather than a global value. The same raw key held by another guardian is simply a
    # different request: it must be independently spendable here, with no coupling between accounts
    # and nothing that could surface their record.
    test 'the same raw key is independently spendable by a different guardian' do
      other_guardian = create(:constituent)
      other_dependent = create(:constituent, first_name: 'Someone', last_name: 'Else')
      key = SecureRandom.hex(16)
      GuardianRelationship.create!(guardian_user: other_guardian, dependent_user: other_dependent,
                                   relationship_type: 'Parent', portal_creation_key: key,
                                   portal_creation_fingerprint: fake_fingerprint)

      assert_difference ['User.count', 'GuardianRelationship.count'], 1 do
        post_dependent(dependent_body, portal_creation_key: key)
      end

      assert_redirected_to constituent_portal_dashboard_url
      assert_equal 1, GuardianRelationship.where(guardian_id: @guardian.id, portal_creation_key: key).count
      # The other guardian's row is untouched, and nothing about it was disclosed.
      assert_equal 1, GuardianRelationship.where(guardian_id: other_guardian.id, portal_creation_key: key).count
    end

    test 'a malformed key is treated as absent rather than queried' do
      assert_difference 'User.count', 1 do
        post_dependent(dependent_body, portal_creation_key: "' OR 1=1 --")
      end
      assert_redirected_to constituent_portal_dashboard_url
    end

    # The most-travelled real path: the first attempt fails validation, so nothing persisted and the
    # key is unspent. Correcting the error and resubmitting must proceed, not fail closed.
    test 'a corrected retry carrying the same key still creates the dependent' do
      key = SecureRandom.hex(16)
      body = dependent_body

      assert_no_difference 'User.count' do
        post_dependent(body.merge(hearing_disability: false), portal_creation_key: key)
      end

      assert_difference 'User.count', 1 do
        post_dependent(body, portal_creation_key: key)
      end
      assert_redirected_to constituent_portal_dashboard_url
    end

    # --- Guardian-scoped duplicate prevention ---------------------------------------------------
    #
    # A different key means a different request, so these are admission decisions rather than
    # replays. Contact details differ between submissions so exact-contact detection stays out of
    # the way and the identity rule is what is actually under test.

    test 'a new request for an identity the guardian already holds is refused with a way forward' do
      post_dependent(dependent_body, portal_creation_key: SecureRandom.hex(16))

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post_dependent(dependent_body, portal_creation_key: SecureRandom.hex(16))
      end

      assert_match(/already associated with your account/i, flash[:alert])
      assert_match(/contact the MAT Team/i, flash[:alert])
    end

    # Equivalence comes from Users::Constituent.find_duplicates, which lower-cases both names in
    # SQL. A guard comparing raw strings would let this through.
    test 'the identity rule is case and whitespace insensitive' do
      post_dependent(dependent_body(first_name: 'Jane', last_name: 'Doe'),
                     portal_creation_key: SecureRandom.hex(16))

      assert_no_difference 'User.count' do
        post_dependent(dependent_body(first_name: '  jane  ', last_name: 'DOE'),
                       portal_creation_key: SecureRandom.hex(16))
      end
      assert_match(/already associated/i, flash[:alert])
    end

    # The portal submits MM/DD/YYYY. find_duplicates parses string dates with Date.iso8601, so
    # passing the raw submitted value would silently match nothing and admit the duplicate.
    test 'the identity rule holds for the portal MM/DD/YYYY date format' do
      post_dependent(dependent_body(date_of_birth: '05/15/2010'),
                     portal_creation_key: SecureRandom.hex(16))

      assert_no_difference 'User.count' do
        post_dependent(dependent_body(date_of_birth: '05/15/2010'),
                       portal_creation_key: SecureRandom.hex(16))
      end
      assert_match(/already associated/i, flash[:alert])
    end

    test 'the rule reads dependents created by other writers, not only portal ones' do
      paper_dependent = create(:constituent, first_name: 'Paper', last_name: 'Child',
                                             date_of_birth: Date.new(2011, 4, 2))
      GuardianRelationship.create!(guardian_user: @guardian, dependent_user: paper_dependent,
                                   relationship_type: 'Parent')

      assert_no_difference 'User.count' do
        post_dependent(dependent_body(first_name: 'Paper', last_name: 'Child',
                                      date_of_birth: '04/02/2011'),
                       portal_creation_key: SecureRandom.hex(16))
      end
      assert_match(/already associated/i, flash[:alert])
    end

    test 'genuinely distinct dependents are still allowed' do
      post_dependent(dependent_body(date_of_birth: '2010-05-15'), portal_creation_key: SecureRandom.hex(16))

      assert_difference 'User.count', 1 do
        post_dependent(dependent_body(date_of_birth: '2012-09-01'), portal_creation_key: SecureRandom.hex(16))
      end
      assert_redirected_to constituent_portal_dashboard_url
    end

    # The rule is guardian-scoped. Unrelated people sharing a name and birthdate are a soft match
    # for review, not a block -- which is why find_duplicates flags rather than refuses.
    test 'another guardian may hold a dependent with the same name and birthdate' do
      other_guardian = create(:constituent)
      post_dependent(dependent_body, portal_creation_key: SecureRandom.hex(16))

      sign_out
      sign_in_for_controller_test(other_guardian)

      assert_difference 'User.count', 1 do
        post_dependent(dependent_body, portal_creation_key: SecureRandom.hex(16))
      end
      assert_redirected_to constituent_portal_dashboard_url
    end

    teardown do
      # Clean up Current.user to avoid affecting other tests
      Current.user = nil
    end

    private

    # Builds one submission body. Email and phone are distinct per body unless overridden, because
    # an exact email or phone match is a *hard block* in DuplicateDetectionService and refuses before
    # the lock. Replay tests deliberately reuse one body so the second POST really is the same
    # request, contact details included.
    # The replay pair is meaningless split, and a check constraint enforces that, so fixtures that
    # set a key directly must supply a fingerprint too. The value is opaque here: these tests are
    # about the key's scope and the merge repoints, not about fingerprint comparison.
    def fake_fingerprint
      "v1:#{SecureRandom.hex(32)}"
    end

    def dependent_body(**overrides)
      unique = SecureRandom.hex(4)
      {
        first_name: 'Jane',
        last_name: 'Doe',
        date_of_birth: '2010-05-15',
        email: "jane.doe.#{unique}@example.com",
        phone: "555#{format('%07d', SecureRandom.random_number(10_000_000))}",
        hearing_disability: true
      }.merge(overrides)
    end

    def post_dependent(body, portal_creation_key: nil, relationship_type: 'Parent')
      params = {
        dependent: body,
        guardian_relationship: { relationship_type: relationship_type }
      }
      params[:portal_creation_key] = portal_creation_key if portal_creation_key

      post constituent_portal_dependents_url, params: params
    end
  end
end
