# frozen_string_literal: true

require 'test_helper'

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:constituent)
    sign_in_for_controller_test(@user)
  end

  test 'should get edit' do
    get edit_profile_path
    assert_response :success
    assert_select 'h1', 'Edit Profile'
    assert_select 'form[action=?]', profile_path
  end

  test 'should update profile successfully' do
    assert_difference('Event.count', 1) do
      patch profile_path, params: {
        user: {
          first_name: 'Updated First',
          last_name: 'Updated Last',
          email: 'updated@example.com'
        }
      }
    end

    assert_redirected_to constituent_portal_dashboard_path
    assert_equal 'Profile successfully updated', flash[:notice]

    # Verify user was updated
    @user.reload
    assert_equal 'Updated First', @user.first_name
    assert_equal 'Updated Last', @user.last_name
    assert_equal 'updated@example.com', @user.email

    # Verify audit log was created correctly
    event = Event.last
    assert_equal 'profile_updated', event.action
    assert_equal @user.id, event.user_id
    assert_equal @user.id, event.metadata['user_id']
    assert_equal @user.id, event.metadata['updated_by']

    # Verify changes are recorded
    changes = event.metadata['changes']
    assert_equal 'Updated First', changes['first_name']['new']
    assert_equal 'Updated Last', changes['last_name']['new']
    assert_equal 'updated@example.com', changes['email']['new']
  end

  test 'should set Current.user before update' do
    # Verify Current.user is set during the request
    UsersController.any_instance.expects(:set_current_user).once

    patch profile_path, params: {
      user: {
        first_name: 'Test Name'
      }
    }
  end

  test 'should handle validation errors' do
    assert_no_difference('Event.count') do
      patch profile_path, params: {
        user: {
          first_name: '', # Invalid - required field
          email: 'invalid-email' # Invalid format
        }
      }
    end

    assert_response :unprocessable_content
    assert_select '.bg-red-50', text: /error/i # Error message should be displayed
  end

  test 'should redirect admin to admin dashboard after update' do
    admin = create(:admin)
    sign_out
    sign_in_for_controller_test(admin)

    patch profile_path, params: {
      user: {
        first_name: 'Admin Updated'
      }
    }

    assert_redirected_to admin_applications_path
  end

  test 'should redirect evaluator to evaluator dashboard after update' do
    evaluator = create(:evaluator)
    sign_out
    sign_in_for_controller_test(evaluator)

    patch profile_path, params: {
      user: {
        first_name: 'Evaluator Updated'
      }
    }

    assert_redirected_to evaluators_dashboard_path
  end

  test 'should redirect vendor to vendor dashboard after update' do
    vendor = create(:vendor_user)
    sign_out
    sign_in_for_controller_test(vendor)

    patch profile_path, params: {
      user: {
        first_name: 'Vendor Updated'
      }
    }

    assert_redirected_to vendor_portal_dashboard_path
  end

  test 'should not update when not authenticated' do
    sign_out

    patch profile_path, params: {
      user: {
        first_name: 'Should Not Update'
      }
    }

    assert_redirected_to sign_in_path
  end

  test 'should only allow permitted parameters' do
    # Try to update a field that shouldn't be allowed
    patch profile_path, params: {
      user: {
        first_name: 'Allowed Update',
        type: 'Users::Administrator', # Should not be allowed
        status: 'suspended' # Should not be allowed
      }
    }

    @user.reload
    assert_equal 'Allowed Update', @user.first_name
    assert_not_equal 'Users::Administrator', @user.type
    assert_not_equal 'suspended', @user.status
  end

  teardown do
    # Clean up Current.user to avoid affecting other tests
    Current.user = nil
  end
end
