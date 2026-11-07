# frozen_string_literal: true

require 'test_helper'

class TotpReplayAndEnrollmentTest < ActionDispatch::IntegrationTest
  setup do
    Current.reset
    @user = create(:constituent)
  end

  test 'a drift-ahead code cannot authenticate another browser now or when its step arrives' do
    travel_to Time.utc(2026, 11, 6, 12, 0, 5) do
      credential = @user.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Authenticator', last_used_at: 1.minute.ago)
      duplicate = @user.totp_credentials.create!(secret: credential.secret, nickname: 'Duplicate authenticator', last_used_at: 1.minute.ago)
      totp = ROTP::TOTP.new(credential.secret)
      first = password_session
      second = password_session
      code = totp.at(30.seconds.from_now)

      assert_difference('Session.count', 1) { verify(first, code) }
      first.assert_response :success
      assert_equal Time.utc(2026, 11, 6, 12, 0, 30), credential.reload.last_used_at
      assert_equal credential.last_used_at, duplicate.reload.last_used_at
      credential.destroy!

      assert_no_difference('Session.count') { verify(second, code) }
      second.assert_response :unprocessable_content
      travel 30.seconds
      assert_no_difference('Session.count') { verify(second, code) }
      second.assert_response :unprocessable_content
      travel 30.seconds
      assert_difference('Session.count', 1) { verify(second, totp.now) }
      second.assert_response :success
    end
  end

  test 'enrollment ignores supplied seeds and consumes the matched step' do
    travel_to Time.utc(2026, 11, 6, 12, 0, 5) do
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      supplied_secret = 'JBSWY3DPEHPK3PXP'
      get new_credential_two_factor_authentication_path(type: 'totp'), params: { secret: supplied_secret }
      assert_select 'input[name="secret"]', count: 0
      secret = pending_secret
      assert_not_equal supplied_secret, secret
      get new_credential_two_factor_authentication_path(type: 'totp')
      assert_equal secret, pending_secret

      post create_credential_two_factor_authentication_path(type: 'totp'),
           params: { secret: supplied_secret, code: 'invalid', nickname: 'My app' }
      assert_response :unprocessable_content
      assert_select 'input[name="nickname"][value="My app"]'
      assert_equal secret, pending_secret

      pending_cookie = cookies[Rails.application.config.session_options.fetch(:key)]
      code = ROTP::TOTP.new(secret).at(30.seconds.from_now)
      assert_difference('TotpCredential.count', 1) do
        post create_credential_two_factor_authentication_path(type: 'totp'),
             params: { secret: supplied_secret, code: code, nickname: 'My app' }
      end
      credential = @user.totp_credentials.sole
      assert_equal secret, credential.secret
      assert_equal Time.utc(2026, 11, 6, 12, 0, 30), credential.last_used_at
      assert_nil session[TwoFactorAuth::SESSION_KEYS[:metadata]]
      cookies[Rails.application.config.session_options.fetch(:key)] = pending_cookie
      assert_no_difference('TotpCredential.count') do
        post create_credential_two_factor_authentication_path(type: 'totp'), params: { code: code, nickname: 'Retried setup' }
      end
      assert_equal 'My app', credential.reload.nickname
      browser = password_session
      assert_no_difference('Session.count') { verify(browser, code) }
      browser.assert_response :unprocessable_content
    end
  end

  test 'missing or expired pending enrollment cannot be replaced by submitted secret' do
    post sign_in_path, params: { email: @user.email, password: 'password1234' }
    supplied_secret = ROTP::Base32.random
    assert_no_difference('TotpCredential.count') do
      post create_credential_two_factor_authentication_path(type: 'totp'),
           params: { secret: supplied_secret, code: ROTP::TOTP.new(supplied_secret).now }
    end
    assert_redirected_to new_credential_two_factor_authentication_path(type: 'totp')

    freeze_time do
      get new_credential_two_factor_authentication_path(type: 'totp')
      secret = pending_secret
      travel 9.minutes
      get new_credential_two_factor_authentication_path(type: 'totp')
      assert_equal secret, pending_secret
      travel 1.minute
      assert_no_difference('TotpCredential.count') do
        post create_credential_two_factor_authentication_path(type: 'totp'),
             params: { secret: secret, code: ROTP::TOTP.new(secret).now }
      end
      assert_redirected_to new_credential_two_factor_authentication_path(type: 'totp')
      assert_nil session[TwoFactorAuth::SESSION_KEYS[:metadata]]
      follow_redirect!
      assert_not_equal secret, pending_secret
      assert_select '[role="alert"]', text: /#{Regexp.escape(I18n.t('two_factor_verification.errors.expired_totp_setup'))}/
    end
  end

  private

  def pending_secret
    session[TwoFactorAuth::SESSION_KEYS[:metadata]].with_indifferent_access.fetch(:secret)
  end

  def password_session
    open_session do |browser|
      browser.post sign_in_path, params: { email: @user.email, password: 'password1234' }
      browser.assert_redirected_to verify_method_two_factor_authentication_path(type: 'totp')
    end
  end

  def verify(browser, code)
    browser.post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: code }, as: :json
  end
end
