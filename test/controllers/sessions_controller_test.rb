# frozen_string_literal: true

require 'test_helper'

class SessionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = create(:admin)
  end

  def test_should_redirect_admin_without_mfa_to_setup
    post sign_in_path, params: { email: @admin.email, password: 'password123' }

    assert_redirected_to setup_two_factor_authentication_path
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

  def test_should_sign_in_constituent_without_mfa
    user = create(:constituent)

    post sign_in_path, params: { email: user.email, password: 'password123' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_sms_only_login_keeps_two_factor_session_when_sms_send_is_in_progress
    user = create(:constituent)
    user.sms_credentials.create!(
      phone_number: '555-321-9876',
      last_sent_at: Time.current,
      verified_at: Time.current
    )

    SessionsController.any_instance.stubs(:ensure_sms_challenge_for_user).returns(:sending)

    post sign_in_path, params: { email: user.email, password: 'password123' }

    assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')
    assert_equal TwoFactor::SmsLoginChallenge::DUPLICATE_SEND_MESSAGE, flash[:notice]
    assert_equal user.id, session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
  end
end
