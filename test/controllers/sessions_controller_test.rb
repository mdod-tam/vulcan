# frozen_string_literal: true

require 'test_helper'

class SessionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = create(:admin)
  end

  def test_should_sign_in_admin
    post sign_in_path, params: { email: @admin.email, password: 'password123' }

    # Admin sign-in should redirect to admin dashboard
    assert_redirected_to admin_dashboard_path
  end

  def test_should_get_new
    get sign_in_path
    assert_response :success
  end

  def test_should_not_sign_in_with_wrong_credentials
    post sign_in_path, params: {
      email: @admin.email,
      password: 'wrongpassword'
    }
    assert_redirected_to sign_in_path(email_hint: @admin.email)
    follow_redirect!
    assert_match 'Invalid email or password', flash[:alert]
  end
end
