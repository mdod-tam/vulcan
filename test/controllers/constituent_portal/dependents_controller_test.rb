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
      get new_constituent_portal_dependent_url
      assert_response :success
    end

    test 'should create dependent and guardian relationship' do
      dependent_attributes = {
        first_name: 'Jane',
        last_name: 'Doe',
        date_of_birth: '2010-05-15',
        email: 'jane.doe.dependent@example.com',
        phone: '5555550011',
        hearing_disability: true
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

      new_dependent = User.find_by(email: 'jane.doe.dependent@example.com')
      assert(new_dependent, 'New dependent user was not created')
      assert_redirected_to constituent_portal_dashboard_url

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

      # Row counts cannot distinguish rollback from compensating destroy.
      # User#destroy also removes guardian relationships.
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

    # Rollback retains generated contact on the failed user object.
    # Render submitted contact to avoid exposing placeholders or changing contact ownership on retry.
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

    # The retry form must retain the contact strategy selected under the user lock.
    # A guardian contact change can make the pre-lock and locked records select different strategies.
    # This lock hook avoids sharing Mocha stubs across threads.
    test 'a failed attempt renders the contact choice the locked pass applied, not a re-derivation' do
      existing_dependent = create(
        :constituent,
        first_name: 'Locked', last_name: 'Choice', date_of_birth: Date.new(2010, 5, 15),
        email: "portal-dependent-locked-#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      guardian_old_email = @guardian.email
      rotated_email = "rotated-guardian-#{SecureRandom.hex(4)}@example.com"

      # Submitted email matches the pre-lock guardian but differs from the locked guardian.
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

    # The portal has no guardian-contact targets, so typed values remain after the guardian option is selected.
    # The retry form must preserve that option rather than infer ownership from blank fields.
    test 'a failed attempt preserves the guardian contact choice made over typed contact' do
      # The name and birthdate match reaches the forced review-case failure.
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

      # Retry the same body to verify that the guardian contact choice survives failure.
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

    # A duplicate candidate can disappear before participant locks are acquired.
    # A missing candidate must return a retry response instead of an HTTP 500.
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
      Rails.logger.expects(:error).with(regexp_matches(/Date of birth is not a valid date/)).once

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
      assert_match(/Date of birth is not a valid date/, response.body)
      assert_select 'input[name="dependent[date_of_birth]"][value="May 15 2010"]'
    end

    test 'accepts dash and compact date of birth spellings as the same date' do
      { '05-15-2010' => 'Dash', '05152010' => 'Compact' }.each do |spelling, first_name|
        body = dependent_body(date_of_birth: spelling, first_name: first_name)
        post_dependent(body)

        assert_redirected_to constituent_portal_dashboard_url
        assert_equal Date.new(2010, 5, 15), User.find_by!(email: body[:email]).date_of_birth, spelling
      end
    end

    # Replay and admission both run before model validation. Date.parse read 9/9/26 as 2009-09-26,
    # so a rejected date used to fingerprint as the real one and report "already added".
    test 'an unreadable date of birth is refused before replay with a spent key' do
      key = SecureRandom.hex(16)
      body = dependent_body(date_of_birth: '2009-09-26')
      post_dependent(body, portal_creation_key: key)

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post_dependent(body.merge(date_of_birth: '9/9/26'), portal_creation_key: key)
      end

      assert_response :unprocessable_content
      assert_no_match(/already added/i, flash[:notice].to_s)
      assert_match(/Date of birth is not a valid date/, response.body)
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

      dependent_attributes = { first_name: '' }
      guardian_relationship_attributes = { relationship_type: 'Parent' }

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post constituent_portal_dependents_url, params: {
          dependent: dependent_attributes,
          guardian_relationship: guardian_relationship_attributes
        }
      end
      assert_response :unprocessable_content
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
        hearing_disability: true,
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

    test 'portal always creates NEW dependent with skip_user_lookup flag' do
      dependent_attributes = {
        first_name: 'New',
        last_name: 'Dependent',
        date_of_birth: '2010-05-15',
        email: 'new.dependent.portal@example.com',
        phone: '5555559999',
        hearing_disability: true
      }
      guardian_relationship_attributes = {
        relationship_type: 'Parent'
      }

      assert_difference 'User.count', 1 do
        assert_difference 'GuardianRelationship.count', 1 do
          post constituent_portal_dependents_url, params: {
            dependent: dependent_attributes,
            guardian_relationship: guardian_relationship_attributes
          }
        end
      end

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
        delete constituent_portal_dependent_url(dependent_to_delete)
      end

      assert_empty(@guardian.dependents.where(id: dependent_to_delete.id))
      assert_redirected_to constituent_portal_dashboard_url
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

      @dependent.reload
      assert_equal 'Updated Dependent', @dependent.first_name
      assert_equal 'New Last Name', @dependent.last_name
      assert_equal 'updated.dependent@example.com', @dependent.email

      event = Event.last
      assert_equal 'profile_updated_by_guardian', event.action
      assert_equal @guardian.id, event.user_id
      assert_equal @dependent.id, event.metadata['user_id']
      assert_equal @guardian.id, event.metadata['updated_by']

      changes = event.field_changes
      assert_equal({}, event.metadata['changes']['email'], 'encrypted values stay out of metadata')
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
      DependentsController.any_instance.expects(:set_current_user).once

      patch constituent_portal_dependent_path(@dependent), params: {
        dependent: {
          first_name: 'Test Update'
        }
      }
    end

    test 'should show recent changes on dependent show page' do
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

      assert_select '.bg-white', text: /Recent Changes/i
      assert_select 'span', text: @guardian.full_name
      assert_select 'span', text: /First name/i
      assert_select 'span.text-red-600', text: 'Old Name'
      assert_select 'span.text-green-600', text: 'New Name'
    end

    test 'should show recent changes on dependent edit page' do
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

      @dependent.reload
      assert_not_equal 'Should Not Update', @dependent.first_name
    end

    test 'should handle validation errors without logging event' do
      assert_no_difference('Event.count') do
        patch constituent_portal_dependent_path(@dependent), params: {
          dependent: {
            first_name: '',
            email: 'invalid-email'
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
      patch constituent_portal_dependent_path(@dependent), params: {
        dependent: {
          first_name: 'Allowed Update',
          type: 'Users::Administrator',
          status: 'suspended'
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

    # Request replay
    # Reuse the complete body, including contact, so replay tests exercise the exact-contact block.

    test 'replaying an identical request creates exactly one dependent' do
      key = SecureRandom.hex(16)
      body = dependent_body

      assert_difference ['User.count', 'GuardianRelationship.count'], 1 do
        2.times { post_dependent(body, portal_creation_key: key) }
      end

      assert_redirected_to constituent_portal_dashboard_url
      assert_match(/already added/i, flash[:notice])
    end

    # Exact-contact detection precedes the lock. A replay must still reach the form-key lookup.
    test 'a replay is not refused by exact-contact duplicate detection' do
      key = SecureRandom.hex(16)
      body = dependent_body
      post_dependent(body, portal_creation_key: key)

      post_dependent(body, portal_creation_key: key)

      assert_nil flash[:alert]
      assert_match(/already added/i, flash[:notice])
    end

    # Submitted intent must define the fingerprint independently of later guardian contact changes.
    test 'a replay still resolves after the guardian changes their own contact' do
      key = SecureRandom.hex(16)
      # This contact initially selects the guardian strategy. A later guardian edit changes the inferred strategy.
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

    # The key binds the submitted fields, not only identity. Changed input must not report a successful replay.
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

    test 'a successful creation stores the key and its fingerprint together' do
      key = SecureRandom.hex(16)
      post_dependent(dependent_body, portal_creation_key: key)

      relationship = GuardianRelationship.find_by!(guardian_id: @guardian.id, portal_creation_key: key)
      assert relationship.portal_creation_fingerprint.present?
      assert_match(/\Av1:[a-f0-9]{64}\z/, relationship.portal_creation_fingerprint,
                   'the fingerprint must be versioned and keyed, not a bare digest')
    end

    test 'a creation without a key stores neither half of the replay pair' do
      post_dependent(dependent_body)

      relationship = GuardianRelationship.where(guardian_id: @guardian.id).order(:id).last
      assert_nil relationship.portal_creation_key
      assert_nil relationship.portal_creation_fingerprint
    end

    # Replay lookup and key uniqueness use the guardian ID, so another guardian can use the same key.
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
      assert_equal 1, GuardianRelationship.where(guardian_id: other_guardian.id, portal_creation_key: key).count
    end

    test 'a malformed key is treated as absent rather than queried' do
      assert_difference 'User.count', 1 do
        post_dependent(dependent_body, portal_creation_key: "' OR 1=1 --")
      end
      assert_redirected_to constituent_portal_dashboard_url
    end

    # Validation failure leaves the key unused, so a corrected submission can reuse it.
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

    # Duplicate prevention within one guardian account
    # Use different keys and contact values to exercise identity admission without replay or exact-contact blocks.

    test 'a new request for an identity the guardian already holds is refused with a way forward' do
      post_dependent(dependent_body, portal_creation_key: SecureRandom.hex(16))

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        post_dependent(dependent_body, portal_creation_key: SecureRandom.hex(16))
      end

      assert_match(/already associated with your account/i, flash[:alert])
      assert_match(/contact the MAT Team/i, flash[:alert])
    end

    # Users::Constituent.find_duplicates compares lowercase names. Raw string equality would miss this match.
    test 'the identity rule is case and whitespace insensitive' do
      post_dependent(dependent_body(first_name: 'Jane', last_name: 'Doe'),
                     portal_creation_key: SecureRandom.hex(16))

      assert_no_difference 'User.count' do
        post_dependent(dependent_body(first_name: '  jane  ', last_name: 'DOE'),
                       portal_creation_key: SecureRandom.hex(16))
      end
      assert_match(/already associated/i, flash[:alert])
    end

    # find_duplicates parses ISO date strings. The controller must cast the portal date before this lookup.
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

    # A name and birthdate match outside this guardian account opens review instead of blocking creation.
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
      # Clear request context to prevent state leaks between tests.
      Current.user = nil
    end

    private

    # The database requires a fingerprint with each key. This fixture tests key scope, not fingerprint comparison.
    def fake_fingerprint
      "v1:#{SecureRandom.hex(32)}"
    end

    # Use distinct contact for each new body. Replay tests reuse the complete body.
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
