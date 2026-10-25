# frozen_string_literal: true

require 'test_helper'
require 'webauthn/fake_client'

# The pending password step has no Session row to revoke. Exercise its browser token
# through each factor and both session-completion responders.
class PendingTwoFactorPasswordChangeTest < ActionDispatch::IntegrationTest
  setup { Current.reset }
  teardown { Current.reset }

  %i[constituent admin evaluator trainer vendor_user].each do |role|
    test "password reset invalidates pending TOTP sign-in for #{role}" do
      user, credential = user_with_totp(role)
      start_password_step(user)
      token = user.generate_token_for(:password_reset)

      open_session do |reset_browser|
        reset_browser.patch password_path, params: new_password_params.merge(token: token)
        assert_equal sign_in_url, reset_browser.response.location
      end

      assert_no_difference('Session.count') do
        post process_verification_two_factor_authentication_path(type: 'totp'),
             params: { code: ROTP::TOTP.new(credential.secret).now }
      end
      assert_redirected_to sign_in_path
      assert_pending_state_cleared

      assert_no_difference('Session.count') do
        post process_verification_two_factor_authentication_path(type: 'totp'),
             params: { code: ROTP::TOTP.new(credential.secret).now }, as: :json
      end
      assert_response :unprocessable_content
      assert_equal 'user_session', response.parsed_body['error_code']

      start_password_step(user.reload, password: 'ChangedPassword123!')
      assert_difference('Session.count', 1) do
        post process_verification_two_factor_authentication_path(type: 'totp'),
             params: { code: ROTP::TOTP.new(credential.secret).now }
      end
      assert_response :redirect
      assert cookies[:session_token].present?
      assert_pending_state_cleared
    end
  end

  test 'invalid or rolled-back password changes preserve a pending password step' do
    user, credential = user_with_totp
    start_password_step(user)
    result = Users::PasswordUpdateService.new(user, 'incorrect', 'ChangedPassword123!', 'ChangedPassword123!').call
    assert_not result.success?
    User.transaction do
      user.update!(new_password_params)
      raise ActiveRecord::Rollback
    end

    assert_difference('Session.count', 1) do
      post process_verification_two_factor_authentication_path(type: 'totp'),
           params: { code: ROTP::TOTP.new(credential.secret).now }
    end
    assert_redirected_to constituent_portal_dashboard_path
    assert_pending_state_cleared
  end

  test 'a racing password change cannot bind an old password to the new password salt' do
    stale_user, credential = user_with_totp
    User.find(stale_user.id).update!(new_password_params)

    User.stub(:find_by_login_identifier, ->(_identifier) { stale_user }) do
      start_password_step(stale_user)
    end
    assert_nil User.find_by_token_for(:two_factor_sign_in, session[TwoFactorAuth::SESSION_KEYS[:sign_in_token]])

    assert_no_difference('Session.count') do
      post process_verification_two_factor_authentication_path(type: 'totp'),
           params: { code: ROTP::TOTP.new(credential.secret).now }
    end
    assert_redirected_to sign_in_path
    assert_pending_state_cleared
  end

  test 'a password change rejects pending SMS without checking the provider' do
    user, = user_with_totp
    user.sms_credentials.create!(phone_number: '410-555-0188', verified_at: Time.current)
    start_password_step(user)
    TwilioVerifyService.expects(:send_verification).once.returns(success: true, verification_sid: 'TEST_PASSWORD_CHANGE', status: 'pending')
    post select_sms_verification_two_factor_authentication_path
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')
    user.update!(new_password_params)

    TwilioVerifyService.expects(:check_verification).never
    assert_no_difference('Session.count') do
      post process_verification_two_factor_authentication_path(type: 'sms'), params: { code: '123456' }
    end
    assert_redirected_to sign_in_path
    assert_pending_state_cleared
  end

  test 'a password change while SMS is checked rejects the approved result without an exception' do
    user, = user_with_totp
    user.sms_credentials.create!(phone_number: '410-555-0189', verified_at: Time.current)
    start_password_step(user)
    TwilioVerifyService.expects(:send_verification).once.returns(success: true, verification_sid: 'TEST_PASSWORD_CHANGE_DURING_CHECK', status: 'pending')
    post select_sms_verification_two_factor_authentication_path
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')

    check_then_change_password = lambda do |*|
      user.update!(new_password_params)
      { success: true, status: 'approved', valid: true }
    end
    TwilioVerifyService.stub(:check_verification, check_then_change_password) do
      assert_no_difference('Session.count') do
        post process_verification_two_factor_authentication_path(type: 'sms'), params: { code: '123456' }
      end
    end
    assert_redirected_to sign_in_path
    assert_pending_state_cleared
  end

  test 'a password change rejects a real pending security-key assertion before consuming it' do
    original_origins = WebAuthn.configuration.allowed_origins
    original_rp_id = WebAuthn.configuration.rp_id
    WebAuthn.configuration.allowed_origins = ['https://example.com']
    WebAuthn.configuration.rp_id = 'example.com'
    client = WebAuthn::FakeClient.new('https://example.com')
    user = create(:constituent)
    registration = client.create(challenge: SecureRandom.urlsafe_base64(32), rp_id: 'example.com')
    registered = WebAuthn::Credential.from_create(registration)
    credential = create(:webauthn_credential, user: user, external_id: registered.id, public_key: registered.public_key)
    start_password_step(user)
    get verification_options_two_factor_authentication_path(type: 'webauthn'), as: :json
    assert_response :success
    assertion = client.get(challenge: response.parsed_body.fetch('challenge'), rp_id: 'example.com', user_verified: true, sign_count: 1)
    user.update!(new_password_params)

    assert_no_difference('Session.count') do
      post process_verification_two_factor_authentication_path(type: 'webauthn'),
           params: { two_factor_authentication: assertion }, as: :json
    end
    assert_response :unprocessable_content
    assert_equal 'user_session', response.parsed_body['error_code']
    assert_equal 0, credential.reload.sign_count
    assert_pending_state_cleared
  ensure
    WebAuthn.configuration.allowed_origins = original_origins
    WebAuthn.configuration.rp_id = original_rp_id
  end

  %i[html json].each do |format|
    test "password change after factor verification prevents #{format} session issuance" do
      user, credential = user_with_totp
      start_password_step(user)
      original_lock = User.method(:lock_for_merge_integrity!)
      lock_calls = 0
      change_password_before_lock = lambda do |*users|
        lock_calls += 1
        assert credential.reload.last_used_at.present?, 'the factor must have verified before the password change'
        user.update!(new_password_params)
        original_lock.call(*users)
      end

      User.stub(:lock_for_merge_integrity!, change_password_before_lock) do
        assert_no_difference('Session.count') do
          request_options = format == :json ? { as: :json } : {}
          post process_verification_two_factor_authentication_path(type: 'totp'),
               params: { code: ROTP::TOTP.new(credential.secret).now }, **request_options
        end
      end

      assert_equal 1, lock_calls
      if format == :json
        assert_response :unprocessable_content
        assert_equal 'session_failed', response.parsed_body['error_code']
      else
        assert_redirected_to sign_in_path
        assert_equal I18n.t('alerts.session_fail'), flash[:alert]
      end
      assert cookies[:session_token].blank?
      assert_pending_state_cleared
    end
  end

  private

  def user_with_totp(role = :constituent)
    user = create(role)
    credential = user.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Authenticator')
    [user, credential]
  end

  def start_password_step(user, password: 'password1234')
    post sign_in_path, params: { email: user.email, password: password }
    assert_response :redirect
    assert_equal user.id, session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
    assert session[TwoFactorAuth::SESSION_KEYS[:sign_in_token]].present?
    assert cookies[:session_token].blank?
  end

  def new_password_params
    { password: 'ChangedPassword123!', password_confirmation: 'ChangedPassword123!' }
  end

  def assert_pending_state_cleared
    %i[temp_user_id sign_in_token challenge type metadata return_path].each do |key|
      assert_nil session[TwoFactorAuth::SESSION_KEYS[key]], "#{key} must not survive completion or rejection"
    end
  end
end
