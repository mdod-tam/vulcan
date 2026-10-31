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

    @user.reload
    assert_equal 'Updated First', @user.first_name
    assert_equal 'Updated Last', @user.last_name
    assert_equal 'updated@example.com', @user.email

    event = Event.last
    assert_equal 'profile_updated', event.action
    assert_equal @user.id, event.user_id
    assert_equal @user.id, event.metadata['user_id']
    assert_equal @user.id, event.metadata['updated_by']

    changes = event.field_changes
    assert_equal 'U*** F***', changes['first_name']['new']
    assert_equal 'U*** L***', changes['last_name']['new']
    assert_equal 'u***@e***.com', changes['email']['new']
  end

  %i[inactive suspended].each do |status|
    test "profile edit denies an unmerged #{status} user with an existing session" do
      @user.update!(status: status)
      original_name = @user.first_name
      session_ids = @user.sessions.pluck(:id)
      assert_predicate session_ids, :any?

      assert_no_difference 'Event.count' do
        patch profile_path, params: { user: { first_name: 'Blocked Edit' } }
      end

      assert_redirected_to sign_in_path
      assert_equal original_name, @user.reload.first_name
      assert_empty Session.where(id: session_ids)
      assert_not @user.merged?
    end
  end

  test 'should set Current.user before update' do
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
    assert_select '.bg-danger-50', text: /error/i
  end

  test 'constituent cannot clear portal email from profile while keeping phone' do
    @user.update!(phone: '410-555-0301', phone_type: 'text')
    original_email = @user.email

    assert_no_difference('Event.count') do
      patch profile_path, params: {
        user: {
          first_name: @user.first_name,
          last_name: @user.last_name,
          email: '',
          phone: @user.phone,
          phone_type: @user.phone_type
        }
      }
    end

    assert_response :unprocessable_content
    assert_select '#error_explanation', /Email can't be blank/
    @user.reload
    assert_equal original_email, @user.email
    assert_equal @user, User.find_by_login_identifier(original_email)
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
    patch profile_path, params: {
      user: {
        first_name: 'Allowed Update',
        type: 'Users::Administrator',
        status: 'suspended'
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
