# frozen_string_literal: true

require 'test_helper'

class SessionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = create(:admin)
    @system_audit_actor = User.find_by(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL) ||
                          create(:admin, email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
  end

  def test_should_redirect_admin_without_mfa_to_setup
    post sign_in_path, params: { email: @admin.email, password: 'password1234' }

    assert_redirected_to setup_two_factor_authentication_path
  end

  def test_should_get_new
    get sign_in_path
    assert_response :success
    assert_select 'a[href=?]', new_password_path, text: 'Forgot password?'
  end

  def test_should_get_new_with_public_request_locale
    get sign_in_path(locale: 'es')

    assert_response :success
    assert_select 'h1', 'Iniciar sesión'
    assert_select 'form[action=?]', sign_in_path(locale: 'es')
    assert_select 'a[href=?]', new_password_path(locale: 'es'), text: '¿Olvidó su contraseña?'
    assert_select 'a[href=?]', sign_up_path(locale: 'es'), text: 'Registrarse'
  end

  def test_turbo_stream_accept_on_sign_in_get_returns_a_complete_html_page
    get sign_in_path(locale: 'es'), headers: { 'Accept' => "#{Mime[:turbo_stream]}, text/html, application/xhtml+xml" }

    assert_response :success
    assert_equal 'text/html', response.media_type
    assert_match(/\A<!DOCTYPE html>/i, response.body.lstrip)
    assert_select 'html[lang=es]'
    assert_select 'head title'
    assert_select 'h1#signin-heading', 'Iniciar sesión'
    assert_select '#sign_in_form form[action=?]', sign_in_path(locale: 'es')
    assert_select 'turbo-stream', count: 0
  end

  def test_turbo_stream_accept_on_sign_in_get_redirects_an_authenticated_user
    user = create(:constituent)
    post sign_in_path, params: { contact: user.email, password: 'password1234' }
    assert_redirected_to constituent_portal_dashboard_path

    get sign_in_path, headers: { 'Accept' => "#{Mime[:turbo_stream]}, text/html, application/xhtml+xml" }

    assert_redirected_to constituent_portal_dashboard_path, status: :found
    assert_select 'turbo-stream', count: 0
  end

  def test_invalid_sign_in_post_still_replaces_its_existing_form_with_a_turbo_stream
    post sign_in_path, params: { contact: @admin.email, password: 'incorrect-password' },
                       headers: { 'Accept' => Mime[:turbo_stream].to_s }

    assert_response :success
    assert_equal Mime[:turbo_stream].to_s, response.media_type
    assert_select 'turbo-stream[action=replace][target=sign_in_form]' do
      assert_select 'template #sign_in_form form'
    end
    assert_no_match(/<!DOCTYPE html>/i, response.body)
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

  def test_invalid_credentials_preserve_public_request_locale
    post sign_in_path, params: {
      locale: 'es',
      email: @admin.email,
      password: 'wrongpassword'
    }

    assert_redirected_to sign_in_path(locale: 'es')
    assert_equal I18n.t('controllers.sessions.invalid_credentials', locale: :es), flash[:alert]
  end

  def test_successful_login_notice_follows_public_request_locale
    user = create(:constituent)

    post sign_in_path, params: { locale: 'es', email: user.email, password: 'password1234' }

    assert_equal I18n.t('controllers.application.sign_in.signin_pass', locale: :es), flash[:notice]
  end

  def test_failed_login_increments_failed_attempts
    user = create(:constituent)

    assert_difference -> { user.reload.failed_attempts.to_i }, 1 do
      post sign_in_path, params: { email: user.email, password: 'wrongpassword' }
    end

    assert_redirected_to sign_in_path
  end

  def test_failed_login_rate_limit_returns_neutral_error_and_skips_failed_attempt_mutation
    user = create(:constituent)
    old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    set_auth_rate_limit_policy('sign_in_attempt_rate_limit_ip', 1)
    set_auth_rate_limit_policy('sign_in_attempt_rate_period', 1)

    post sign_in_path, params: { email: user.email, password: 'wrongpassword' }

    assert_difference -> { Event.where(action: 'sign_in_attempt_rate_limited', user: @system_audit_actor).count }, 1 do
      assert_no_difference -> { user.reload.failed_attempts.to_i } do
        post sign_in_path, params: { email: user.email, password: 'wrongpassword' }
      end
    end

    assert_redirected_to sign_in_path
    event = Event.where(action: 'sign_in_attempt_rate_limited', user: @system_audit_actor).last
    assert event.metadata['request_ip_digest'].present?
    assert event.metadata['submitted_contact_digest'].present?
    assert_not_includes event.metadata.values.join(' '), user.email
  ensure
    Rails.cache = old_cache
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
      post sign_in_path, params: { email: user.email, password: 'password1234' }
    end

    assert_redirected_to sign_in_path
  end

  def test_expired_lock_allows_sign_in_with_valid_password
    user = create(:constituent, failed_attempts: UserAuthentication::MAX_LOGIN_ATTEMPTS, locked_at: expired_lock_time)

    assert_difference('Session.count', 1) do
      post sign_in_path, params: { email: user.email, password: 'password1234' }
    end

    assert_redirected_to constituent_portal_dashboard_path
    user.reload
    assert_equal 0, user.failed_attempts
    assert_nil user.locked_at
  end

  def test_wrong_password_after_the_lock_expires_starts_a_fresh_count
    user = create(:constituent, failed_attempts: UserAuthentication::MAX_LOGIN_ATTEMPTS, locked_at: expired_lock_time)

    post sign_in_path, params: { email: user.email, password: 'wrongpassword' }

    user.reload
    assert_equal 1, user.failed_attempts
    assert_not user.account_locked?
  end

  def test_a_session_that_cannot_save_rolls_back_sign_in_bookkeeping
    user = create(:constituent, failed_attempts: 3)
    Session.any_instance.stubs(:save).returns(false)

    assert_no_difference('Session.count') do
      post sign_in_path, params: { email: user.email, password: 'password1234' }
    end

    assert_redirected_to sign_in_path
    assert_equal I18n.t('alerts.session_fail'), flash[:alert]
    user.reload
    assert_equal 3, user.failed_attempts
    assert_nil user.last_sign_in_at
  end

  def test_should_sign_in_constituent_without_mfa
    user = create(:constituent)

    post sign_in_path, params: { email: user.email, password: 'password1234' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_successful_login_does_not_check_failed_attempt_rate_limit
    user = create(:constituent)

    AuthRateLimit.expects(:check!).never

    post sign_in_path, params: { email: user.email, password: 'password1234' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_should_sign_in_with_normalized_email
    user = create(:constituent, email: 'casey@example.com')

    post sign_in_path, params: { email: "  #{user.email.upcase}  ", password: 'password1234' }

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

    post sign_in_path, params: { email: user.email, password: 'password1234' }

    assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')
    assert_equal I18n.t('two_factor_verification.sms.sending', locale: :en), flash[:notice]
    assert_equal user.id, session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
  end

  def test_should_sign_in_constituent_by_phone
    user = create(:constituent)

    post sign_in_path, params: { contact: user.phone, password: 'password1234' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_should_sign_in_with_normalized_phone
    create(:constituent, phone: '410-555-0100')

    post sign_in_path, params: { contact: '4105550100', password: 'password1234' }

    assert_redirected_to constituent_portal_dashboard_path
  end

  def test_paper_no_email_user_cannot_sign_in_with_phone
    user = create_paper_no_email_constituent(phone: '410-555-0188', phone_type: 'voice',
                                             first_name: 'Paper', last_name: 'NoEmail')

    post sign_in_path, params: { contact: user.phone, password: 'password1234' }

    assert_redirected_to sign_in_path
    follow_redirect!
    assert_match I18n.t('controllers.sessions.invalid_credentials'), flash[:alert]
  end

  def test_failed_login_by_phone_increments_failed_attempts
    user = create(:constituent)

    assert_difference -> { user.reload.failed_attempts.to_i }, 1 do
      post sign_in_path, params: { contact: user.phone, password: 'wrongpassword' }
    end

    assert_redirected_to sign_in_path
  end

  def test_guardian_generated_synthetic_phone_cannot_sign_in
    create(:constituent, phone: '000-234-5678', email: "dep.#{SecureRandom.hex(3)}@system.matvulcan.local")

    post sign_in_path, params: { contact: '0002345678', password: 'password1234' }

    assert_redirected_to sign_in_path
    follow_redirect!
    assert_match I18n.t('controllers.sessions.invalid_credentials'), flash[:alert]
  end

  def test_system_email_cannot_sign_in
    user = create(:constituent, email: "dep.#{SecureRandom.hex(3)}@system.matvulcan.local", phone: '410-555-0177')

    post sign_in_path, params: { contact: user.email, password: 'password1234' }

    assert_redirected_to sign_in_path
  end

  def test_malformed_email_shaped_identifier_cannot_sign_in
    phone = '410-555-0143'
    user = create_paper_no_email_constituent(phone: phone, phone_type: 'voice',
                                             first_name: 'Paper', last_name: 'NoEmail')

    post sign_in_path, params: { contact: '4105550143@', password: 'password1234' }

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

  private

  def expired_lock_time
    (UserAuthentication::LOCK_DURATION + 1.minute).ago
  end

  def set_auth_rate_limit_policy(key, value)
    policy = Policy.find_or_initialize_by(key: key)
    if policy.new_record?
      policy.value = value
      policy.save!
    else
      policy.update_column(:value, value)
    end
  end
end
