# frozen_string_literal: true

require 'test_helper'
require 'webauthn/fake_client'

class ReauthenticationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:constituent)
    Current.reset
    post sign_in_path, params: { contact: @user.email, password: 'password1234' }
    assert_redirected_to constituent_portal_dashboard_path
    @record = @user.sessions.order(:id).last
  end

  test 'password reauthentication rotates bearer while preserving the bound session and local return path' do
    original_cookie = cookies[:session_token]
    original_digest = @record.session_token_digest
    travel 6.minutes do
      get new_reauthentication_path(return_to: edit_profile_path)
      assert_response :success
      assert_equal 'no-store', response.headers['Cache-Control']
      assert_select 'input[type=password][autocomplete=current-password]'

      post reauthentication_path, params: { password: 'password1234', factor_type: 'password', return_to: edit_profile_path }
      assert_redirected_to edit_profile_path
      assert_not_equal original_digest, @record.reload.session_token_digest
      assert @record.freshly_authenticated?(user: @user)
    end

    cookies[:session_token] = original_cookie
    get edit_profile_path
    assert_redirected_to sign_in_path
    assert_equal 1, @user.sessions.count
  end

  test 'wrong password cannot rotate bearer or create fresh authority' do
    @record.update!(reauthenticated_at: 6.minutes.ago)
    digest = @record.session_token_digest
    post reauthentication_path, params: { password: 'wrong', factor_type: 'password' }
    assert_response :unprocessable_content
    assert_equal digest, @record.reload.session_token_digest
    assert_not @record.freshly_authenticated?(user: @user)
    assert_equal 1, @user.reload.failed_attempts
  end

  test 'an enrolled factor cannot be bypassed by selecting password only' do
    credential = @user.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Current app', last_used_at: 1.minute.ago)
    @record.update!(reauthenticated_at: 6.minutes.ago)
    post reauthentication_path, params: { password: 'password1234', factor_type: 'password' }
    assert_response :unprocessable_content
    assert_not @record.reload.freshly_authenticated?(user: @user)

    post reauthentication_path, params: { password: 'password1234', factor_type: 'totp', code: ROTP::TOTP.new(credential.secret).now }
    assert_redirected_to edit_profile_path
    assert @record.reload.freshly_authenticated?(user: @user)

    post reauthentication_path, params: { password: 'password1234', factor_type: 'totp', code: ROTP::TOTP.new(credential.secret).now }
    assert_response :unprocessable_content
  end

  test 'external return destinations are discarded' do
    post reauthentication_path, params: { password: 'password1234', factor_type: 'password', return_to: '//example.net/collect' }
    assert_redirected_to edit_profile_path
  end

  test 'SMS reauthentication proves an enrolled number and rotates the same signed session' do
    credential = @user.sms_credentials.create!(phone_number: '410-555-0191', verified_at: Time.current)
    @record.update!(reauthenticated_at: 6.minutes.ago)
    digest = @record.session_token_digest

    post sms_code_reauthentication_path, params: { password: 'password1234', credential_id: credential.id }, as: :json
    assert_response :success
    attempt = SmsVerificationAttempt.find_by!(purpose: 'reauthentication')
    assert_nil attempt.approved_at

    post reauthentication_path, params: {
      password: 'password1234', factor_type: 'sms', credential_id: credential.id, code: '123456', credential: ''
    }
    assert_redirected_to edit_profile_path
    assert @record.reload.freshly_authenticated?(user: @user)
    assert_not_equal digest, @record.session_token_digest
    assert attempt.reload.approved_at
    assert_equal [@record.id], @user.sessions.pluck(:id)
  end

  test 'an existing SMS login challenge cannot be adopted as reauthentication proof' do
    credential = @user.sms_credentials.create!(phone_number: '410-555-0192', verified_at: Time.current)
    @record.update!(reauthenticated_at: 6.minutes.ago)
    digest = @record.session_token_digest
    open_session do |browser|
      browser.post sign_in_path, params: { contact: @user.email, password: 'password1234' }
      browser.assert_redirected_to verify_method_two_factor_authentication_path(type: 'sms')
    end

    post sms_code_reauthentication_path, params: { password: 'password1234', credential_id: credential.id }, as: :json
    assert_response :unprocessable_content
    assert_not @record.reload.freshly_authenticated?(user: @user)
    assert_equal digest, @record.session_token_digest
    assert_equal ['login'], SmsVerificationAttempt.distinct.pluck(:purpose)
  end

  test 'an expired freshness grant cannot enroll or delete a factor' do
    credential = @user.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Current app')
    @record.update!(reauthenticated_at: 6.minutes.ago)

    assert_no_difference -> { @user.totp_credentials.count } do
      delete destroy_credential_two_factor_authentication_path(type: 'totp', id: credential.id)
    end
    assert_redirected_to new_reauthentication_path(return_to: new_credential_two_factor_authentication_path(type: 'totp'))
  end

  test 'a security generation change invalidates a pending WebAuthn challenge' do
    @user.webauthn_credentials.create!(external_id: SecureRandom.base64(32), public_key: 'key', sign_count: 0, nickname: 'Key')
    post webauthn_options_reauthentication_path, params: { password: 'password1234' }, as: :json
    assert_response :success
    User.transaction { User.lock_for_merge_integrity!(@user).fetch(@user.id).advance_security_version! }
    digest = @record.reload.session_token_digest

    post reauthentication_path, params: { password: 'password1234', factor_type: 'webauthn', credential: '{}' }
    assert_response :unprocessable_content
    assert_equal digest, @record.reload.session_token_digest
  end

  test 'a real WebAuthn assertion rotates the same session and its old browser context cannot be replayed' do
    original_origins = WebAuthn.configuration.allowed_origins
    original_rp_id = WebAuthn.configuration.rp_id
    WebAuthn.configuration.allowed_origins = ['https://example.com']
    WebAuthn.configuration.rp_id = 'example.com'
    client = WebAuthn::FakeClient.new('https://example.com')
    registration = client.create(challenge: SecureRandom.urlsafe_base64(32), rp_id: 'example.com')
    registered = WebAuthn::Credential.from_create(registration)
    credential = @user.webauthn_credentials.create!(external_id: registered.id, public_key: registered.public_key,
                                                    nickname: 'Real verifier key', sign_count: 0)
    @record.update!(reauthenticated_at: 6.minutes.ago)
    original_digest = @record.session_token_digest

    post webauthn_options_reauthentication_path, params: { password: 'password1234' }, as: :json
    assert_response :success
    challenge = response.parsed_body.fetch('challenge')
    assert_includes response.parsed_body.fetch('allowCredentials').pluck('id'), credential.external_id
    session_cookie_key = Rails.application.config.session_options.fetch(:key)
    original_context_cookie = cookies[session_cookie_key]
    assert original_context_cookie.present?
    assertion = client.get(challenge: challenge, rp_id: 'example.com', user_verified: true, sign_count: 1)

    post reauthentication_path, params: { password: 'password1234', factor_type: 'webauthn', credential: assertion.to_json }
    assert_redirected_to edit_profile_path
    assert_equal [@record.id], @user.sessions.pluck(:id)
    assert_not_equal original_digest, @record.reload.session_token_digest
    assert @record.freshly_authenticated?(user: @user)
    assert_equal 1, credential.reload.sign_count
    rotated_digest = @record.session_token_digest
    authenticated_at = @record.reauthenticated_at

    post reauthentication_path, params: { password: 'password1234', factor_type: 'webauthn', credential: assertion.to_json }
    assert_response :unprocessable_content
    assert_equal rotated_digest, @record.reload.session_token_digest

    cookies[session_cookie_key] = original_context_cookie
    fresh_assertion_for_old_challenge = client.get(challenge: challenge, rp_id: 'example.com', user_verified: true, sign_count: 2)
    post reauthentication_path, params: {
      password: 'password1234', factor_type: 'webauthn', credential: fresh_assertion_for_old_challenge.to_json
    }
    assert_response :unprocessable_content
    assert_equal rotated_digest, @record.reload.session_token_digest
    assert_equal authenticated_at, @record.reauthenticated_at
    assert_equal 1, credential.reload.sign_count, 'An old context must be rejected before consuming another valid signature'
    assert_equal [@record.id], @user.sessions.pluck(:id)
    assert_equal 1, Event.where(action: 'session_reauthenticated', auditable: @record).count
  ensure
    WebAuthn.configuration.allowed_origins = original_origins
    WebAuthn.configuration.rp_id = original_rp_id
  end
end
