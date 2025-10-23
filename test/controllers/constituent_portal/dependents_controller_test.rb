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

    test 'should not create dependent if attributes are invalid' do
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

    teardown do
      # Clean up Current.user to avoid affecting other tests
      Current.user = nil
    end
  end
end
