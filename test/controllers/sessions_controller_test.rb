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
    assert_select 'a[href=?]', new_password_path, text: 'Forgot password?'
  end

  def test_should_not_sign_in_with_wrong_credentials
    post sign_in_path, params: {
      email: @admin.email,
      password: 'wrongpassword'
    }
    assert_redirected_to sign_in_path
    follow_redirect!
    assert_match I18n.t('controllers.sessions.invalid_credentials'), flash[:alert]
  end

  def test_failed_login_increments_failed_attempts
    user = create(:constituent)

    assert_difference -> { user.reload.failed_attempts.to_i }, 1 do
      post sign_in_path, params: { email: user.email, password: 'wrongpassword' }
    end

    assert_redirected_to sign_in_path
  end

  def test_repeated_failed_logins_lock_account
    user = create(:constituent)

    UserAuthentication::MAX_LOGIN_ATTEMPTS.times do
      post sign_in_path, params: { email: user.email, password: 'wrongpassword' }
    end

    assert user.reload.account_locked?
    assert_not_nil user.locked_at
  end

  def test_locked_account_cannot_sign_in_with_valid_password
    user = create(:constituent, failed_attempts: UserAuthentication::MAX_LOGIN_ATTEMPTS, locked_at: Time.current)

    assert_no_difference('Session.count') do
      post sign_in_path, params: { email: user.email, password: 'password123' }
    end

    assert_redirected_to sign_in_path
  end

  def test_should_sign_in_constituent_without_mfa
    user = create(:constituent)

    post sign_in_path, params: { email: user.email, password: 'password123' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_should_sign_in_with_normalized_email
    user = create(:constituent, email: 'casey@example.com')

    post sign_in_path, params: { email: "  #{user.email.upcase}  ", password: 'password123' }

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

  def test_should_sign_in_constituent_by_phone
    user = create(:constituent)

    post sign_in_path, params: { contact: user.phone, password: 'password123' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_should_sign_in_with_normalized_phone
    user = create(:constituent, phone: '410-555-0100')

    post sign_in_path, params: { contact: '4105550100', password: 'password123' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_backward_compat_email_param_still_works
    user = create(:constituent)

    post sign_in_path, params: { email: user.email, password: 'password123' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_paper_no_email_user_signs_in_with_phone
    user = nil
    Current.paper_context = true
    begin
      user = Users::Constituent.create!(
        first_name: 'Paper', last_name: 'NoEmail',
        phone: '410-555-0188',
        phone_type: 'voice',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password123', password_confirmation: 'password123',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    post sign_in_path, params: { contact: user.phone, password: 'password123' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_paper_no_email_user_signs_in_with_phone_then_sms_2fa
    user = nil
    Current.paper_context = true
    begin
      user = Users::Constituent.create!(
        first_name: 'Paper', last_name: 'Sms2fa',
        phone: '410-555-0189',
        phone_type: 'voice',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password123', password_confirmation: 'password123',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    user.sms_credentials.create!(
      phone_number: '555-321-9876',
      last_sent_at: Time.current,
      verified_at: Time.current
    )

    SessionsController.any_instance.stubs(:ensure_sms_challenge_for_user).returns(:sending)

    post sign_in_path, params: { contact: user.phone, password: 'password123' }

    assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')
    assert_equal user.id, session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
  end

  def test_failed_login_by_phone_increments_failed_attempts
    user = create(:constituent)

    assert_difference -> { user.reload.failed_attempts.to_i }, 1 do
      post sign_in_path, params: { contact: user.phone, password: 'wrongpassword' }
    end

    assert_redirected_to sign_in_path
  end

  def test_locked_account_cannot_sign_in_by_phone
    user = create(:constituent, failed_attempts: UserAuthentication::MAX_LOGIN_ATTEMPTS, locked_at: Time.current)

    assert_no_difference('Session.count') do
      post sign_in_path, params: { contact: user.phone, password: 'password123' }
    end

    assert_redirected_to sign_in_path
  end

  def test_placeholder_phone_cannot_sign_in
    user = create(:constituent, phone: '000-000-5678', email: "dep.#{SecureRandom.hex(3)}@system.matvulcan.local")

    post sign_in_path, params: { contact: user.phone, password: 'password123' }

    assert_redirected_to sign_in_path
    follow_redirect!
    assert_match I18n.t('controllers.sessions.invalid_credentials'), flash[:alert]
  end

  def test_guardian_generated_synthetic_phone_cannot_sign_in
    user = create(:constituent, phone: '000-234-5678', email: "dep.#{SecureRandom.hex(3)}@system.matvulcan.local")

    post sign_in_path, params: { contact: '0002345678', password: 'password123' }

    assert_redirected_to sign_in_path
    follow_redirect!
    assert_match I18n.t('controllers.sessions.invalid_credentials'), flash[:alert]
  end

  def test_system_email_cannot_sign_in
    user = create(:constituent, email: "dep.#{SecureRandom.hex(3)}@system.matvulcan.local", phone: '410-555-0177')

    post sign_in_path, params: { contact: user.email, password: 'password123' }

    assert_redirected_to sign_in_path
  end

  def test_malformed_email_shaped_identifier_cannot_sign_in
    phone = '410-555-0143'
    user = nil
    Current.paper_context = true
    begin
      user = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'MalformedSignIn',
        phone: phone,
        phone_type: 'voice',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password123', password_confirmation: 'password123',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    post sign_in_path, params: { contact: '4105550143@', password: 'password123' }

    assert_redirected_to sign_in_path
    follow_redirect!
    assert_match I18n.t('controllers.sessions.invalid_credentials'), flash[:alert]
    assert_equal user, User.find_by_phone(phone)
  end

  def test_failed_login_redirect_has_no_contact_in_url
    user = create(:constituent)

    post sign_in_path, params: { contact: user.phone, password: 'wrongpassword' }

    assert_redirected_to sign_in_path
    assert_nil URI(response.redirect_url).query
  end
end
