# frozen_string_literal: true

require 'application_system_test_case'
require 'webauthn/fake_client'

class SecurityKeyFeedbackTest < ApplicationSystemTestCase
  %i[en es].each do |locale|
    test "security key failures remain private and retry completes sign in in #{locale}" do
      @locale = locale
      original_origins = WebAuthn.configuration.allowed_origins
      original_rp_id = WebAuthn.configuration.rp_id
      visit sign_in_path(locale: locale)
      capture('security-key-sign-in')
      origin = URI.parse(page.current_url)
      WebAuthn.configuration.allowed_origins = ["#{origin.scheme}://#{origin.host}:#{origin.port}"]
      WebAuthn.configuration.rp_id = origin.host
      client = WebAuthn::FakeClient.new(WebAuthn.configuration.allowed_origins.first)
      user = create(:constituent, email_verified: true, verified: true)
      registration = client.create(challenge: SecureRandom.urlsafe_base64(32), rp_id: origin.host)
      credential = WebAuthn::Credential.from_create(registration)
      create(:webauthn_credential, user: user, external_id: credential.id, public_key: credential.public_key)

      user.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Authenticator')
      user.sms_credentials.create!(phone_number: '410-555-1234', verified_at: Time.current)

      fill_in 'contact-input', with: user.email
      fill_in 'password-input', with: 'password123'
      click_button I18n.t('sessions.form.submit', locale: locale)
      assert_current_path verify_two_factor_authentication_path(locale: locale)
      assert_selector 'h1', text: I18n.t('two_factor_verification.choice.heading', locale: locale)
      capture('security-key-method-choice')
      exercise_code_methods(user.totp_credentials.sole)
      click_link I18n.t('two_factor_verification.common.use_key', locale: locale)
      assert_current_path verify_method_two_factor_authentication_path(type: 'webauthn', locale: locale)
      assert_selector "html[lang='#{locale}']", visible: :all
      assert_selector 'h1', text: I18n.t('security_key_verification.page.heading', locale: locale)
      assert_selector '#security-key-feedback[role="status"][aria-live="polite"][aria-atomic="true"]', visible: :all
      assert_selector 'button[aria-describedby="security-key-feedback"]'
      capture('security-key-ready')

      page.execute_script(<<~JS)
        const originalFetch = window.fetch;
        window.fetch = (...args) => {
          window.fetch = originalFetch;
          return Promise.reject(new TypeError('Simulated offline options request'));
        };
      JS
      click_button verification_button
      assert_feedback(:optionsError)
      capture('security-key-options-failure')

      install_authenticator_prompt
      click_button verification_button
      assert_button verification_button, disabled: true
      assert_selector '#security-key-feedback', text: feedback(:preparing)
      assert_selector 'button[aria-disabled="true"]'
      assert_selector 'html[data-key-prompt="ready"]', visible: :all
      capture('security-key-pending')
      page.execute_script("window.keyPrompt.reject(new DOMException('User cancelled', 'NotAllowedError'))")
      assert_feedback(:NotAllowedError)
      capture('security-key-cancelled')

      click_button verification_button
      assertion = sign_assertion(client, origin.host)
      assertion['id'] = assertion['rawId'] = Base64.urlsafe_encode64('unknown-key', padding: false)
      finish_prompt(assertion)
      assert_feedback(:failed)
      assert_no_text 'Credential not found'
      assert_button verification_button, disabled: false
      assert_current_path verify_method_two_factor_authentication_path(type: 'webauthn', locale: locale)
      page.current_window.resize_to(390, 844)
      capture('security-key-server-rejection-narrow')

      click_button verification_button
      assertion = sign_assertion(client, origin.host)
      user.update!(status: :suspended)
      finish_prompt(assertion)
      assert_selector '#security-key-feedback', text: code_copy('errors.user_session')
      assert_button verification_button, disabled: false
      assert_equal 0, user.webauthn_credentials.sole.reload.sign_count
      assert_empty user.sessions
      capture('security-key-missing-session-narrow')
      user.update!(status: :active)

      TwoFactorAuthenticationsController.any_instance.expects(:_create_and_set_session_cookie).returns(nil)
      click_button verification_button
      finish_prompt(sign_assertion(client, origin.host))
      assert_feedback(:session_failed)
      capture('security-key-session-failure-narrow')
      TwoFactorAuthenticationsController.any_instance.unstub(:_create_and_set_session_cookie)

      visit sign_in_path(locale: locale)
      fill_in 'contact-input', with: user.email
      fill_in 'password-input', with: 'password123'
      click_button I18n.t('sessions.form.submit', locale: locale)
      click_link I18n.t('two_factor_verification.choice.key', locale: locale)
      install_authenticator_prompt
      click_button verification_button
      finish_prompt(sign_assertion(client, origin.host, sign_count: 2))
      assert_current_path constituent_portal_dashboard_path, ignore_query: true
      assert_selector 'h1', text: 'Dashboard'
      assert_equal 2, user.webauthn_credentials.sole.reload.sign_count
      capture('security-key-retry-signed-in')
    ensure
      WebAuthn.configuration.allowed_origins = original_origins
      WebAuthn.configuration.rp_id = original_rp_id
    end
  end

  test 'public locale stays on verification while setup retains its default language' do
    @locale = :es
    user = create(:constituent, email_verified: true, verified: true)
    visit sign_in_path(locale: :es)
    fill_in 'contact-input', with: user.email
    fill_in 'password-input', with: 'password123'
    click_button I18n.t('sessions.form.submit', locale: :es)
    assert_current_path constituent_portal_dashboard_path(locale: :es)
    visit setup_two_factor_authentication_path(locale: :es)
    assert_selector 'html[lang=en]', visible: :all
    assert_selector 'h1', text: 'Secure Your Account'
    capture('mfa-setup-default-language')

    user.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Authenticator')
    user.sms_credentials.create!(phone_number: '410-555-1234', verified_at: Time.current)
    visit setup_two_factor_authentication_path(locale: :es)
    assert_text I18n.t('two_factor_verification.already_secured', locale: :en)
    capture('mfa-already-secured-default-language')

    click_button 'Sign Out', match: :first
    assert_current_path sign_in_path
    visit sign_in_path(locale: :es)
    fill_in 'contact-input', with: user.email
    fill_in 'password-input', with: 'password123'
    click_button I18n.t('sessions.form.submit', locale: :es)
    assert_current_path verify_two_factor_authentication_path(locale: :es)
    visit verify_method_two_factor_authentication_path(type: 'unknown', locale: :es)
    assert_selector 'html[lang=es]', visible: :all
    assert_text I18n.t('two_factor_verification.errors.invalid_method', locale: :es)
    page.current_window.resize_to(390, 844)
    capture('mfa-invalid-method-narrow')
  end

  private

  def exercise_code_methods(credential)
    click_link I18n.t('two_factor_verification.choice.totp', locale: @locale)
    assert_current_path verify_method_two_factor_authentication_path(type: 'totp', locale: @locale)
    assert_selector 'h1', text: code_copy('totp.heading')
    capture('mfa-totp-ready')
    totp = ROTP::TOTP.new(credential.secret)
    invalid_code = (0..10).map { |n| format('%06d', n) }.find { |code| !totp.verify(code, drift_behind: 30, drift_ahead: 30) }
    fill_in code_copy('common.code_label'), with: invalid_code
    click_button code_copy('common.submit')
    assert_text code_copy('errors.invalid_code')
    assert_field code_copy('common.code_label')
    page.current_window.resize_to(390, 844)
    capture('mfa-totp-invalid-narrow')
    page.current_window.resize_to(1200, 900)

    TwilioVerifyService.stubs(:send_verification).returns(success: true, verification_sid: 'TEST_LOCALE_SMS', status: 'pending')
    click_button code_copy('common.use_sms')
    assert_current_path verify_method_two_factor_authentication_path(type: 'sms', locale: @locale)
    assert_text code_copy('sms.sent')
    assert_selector 'h1', text: code_copy('sms.heading')
    capture('mfa-sms-sent')
    click_link code_copy('sms.resend')
    assert_selector '#sms_resend', text: /#{@locale == :es ? 'Espere' : 'Please wait'} \d+/
    capture('mfa-sms-resend-wait')

    TwilioVerifyService.stubs(:check_verification).returns(success: true, status: 'max_attempts_reached', valid: false)
    fill_in code_copy('common.code_label'), with: '123456'
    click_button code_copy('common.submit')
    assert_text code_copy('errors.max_attempts_reached')
    assert_button code_copy('sms.send')
    page.current_window.resize_to(390, 844)
    capture('mfa-sms-expired-narrow')
    click_button code_copy('sms.send')
    assert_field code_copy('common.code_label')
    assert_button code_copy('common.submit')
    capture('mfa-sms-retry-narrow')
    page.current_window.resize_to(1200, 900)
  end

  def code_copy(key)
    I18n.t("two_factor_verification.#{key}", locale: @locale)
  end

  def verification_button
    I18n.t('security_key_verification.page.submit', locale: @locale)
  end

  def feedback(key, locale: @locale)
    I18n.t("security_key_verification.feedback.#{key}", locale: locale)
  end

  def assert_feedback(key, locale: @locale)
    assert_selector '#security-key-feedback', text: feedback(key, locale: locale)
    assert_button verification_button, disabled: false
    assert_selector 'button[aria-disabled="false"]'
  end

  def install_authenticator_prompt
    page.execute_script(<<~'JS')
      navigator.credentials.get = ({publicKey}) => new Promise((resolve, reject) => {
        const bytes = String.fromCharCode(...new Uint8Array(publicKey.challenge));
        window.keyPrompt = {
          resolve,
          reject: error => { document.documentElement.dataset.keyPrompt = ''; reject(error); },
          challenge: btoa(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
        };
        document.documentElement.dataset.keyPrompt = 'ready';
      });
    JS
  end

  def sign_assertion(client, rp_id, sign_count: 1)
    assert_selector 'html[data-key-prompt="ready"]', visible: :all
    challenge = page.evaluate_script('window.keyPrompt.challenge')
    client.get(challenge: challenge, rp_id: rp_id, user_verified: true, sign_count: sign_count)
  end

  def finish_prompt(assertion)
    page.execute_script(<<~JS, assertion)
      const data = arguments[0];
      const buffer = value => Uint8Array.from(atob(value.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0)).buffer;
      data.rawId = buffer(data.rawId);
      for (const key of ['clientDataJSON', 'authenticatorData', 'signature', 'userHandle']) {
        data.response[key] = data.response[key] ? buffer(data.response[key]) : null;
      }
      data.getClientExtensionResults = () => ({});
      document.documentElement.dataset.keyPrompt = '';
      window.keyPrompt.resolve(data);
    JS
  end

  def capture(label)
    assert_empty page.evaluate_script('window.__systemTestErrors')
    label = "#{label}-#{@locale}"
    @screenshot_artifact_label = label
    increment_unique
    page.save_screenshot(image_path, full: true) # rubocop:disable Lint/Debugger -- Required authentication feedback evidence.
    File.write(image_path.sub(/\.png\z/, '.html'), page.html)
    write_screenshot_sidecar(image_path, label: label, html_saved: true)
    puts screenshot_log_message(image_path)
  ensure
    @screenshot_artifact_label = nil
  end
end
