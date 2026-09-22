# frozen_string_literal: true

require 'application_system_test_case'
require 'webauthn/fake_client'

class SecurityKeyFeedbackTest < ApplicationSystemTestCase
  test 'security key failures remain visible and retry completes sign in' do
    original_origins = WebAuthn.configuration.allowed_origins
    original_rp_id = WebAuthn.configuration.rp_id
    visit sign_in_path
    origin = URI.parse(page.current_url)
    WebAuthn.configuration.allowed_origins = ["#{origin.scheme}://#{origin.host}:#{origin.port}"]
    WebAuthn.configuration.rp_id = origin.host
    client = WebAuthn::FakeClient.new(WebAuthn.configuration.allowed_origins.first)
    user = create(:constituent, email_verified: true, verified: true)
    registration = client.create(challenge: SecureRandom.urlsafe_base64(32), rp_id: origin.host)
    credential = WebAuthn::Credential.from_create(registration)
    create(:webauthn_credential, user: user, external_id: credential.id, public_key: credential.public_key)

    fill_in 'contact-input', with: user.email
    fill_in 'password-input', with: 'password123'
    click_button 'Sign In'
    assert_current_path verify_method_two_factor_authentication_path(type: 'webauthn')
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
    click_button 'Verify with Device or Security Key'
    assert_feedback(:optionsError)
    capture('security-key-options-failure')

    install_authenticator_prompt
    click_button 'Verify with Device or Security Key'
    assert_button 'Verify with Device or Security Key', disabled: true
    assert_selector '#security-key-feedback', text: feedback(:preparing)
    assert_selector 'button[aria-disabled="true"]'
    assert_selector 'html[data-key-prompt="ready"]', visible: :all
    capture('security-key-pending')
    page.execute_script("window.keyPrompt.reject(new DOMException('User cancelled', 'NotAllowedError'))")
    assert_feedback(:NotAllowedError)
    capture('security-key-cancelled')

    click_button 'Verify with Device or Security Key'
    assertion = sign_assertion(client, origin.host)
    assertion['id'] = assertion['rawId'] = Base64.urlsafe_encode64('unknown-key', padding: false)
    finish_prompt(assertion)
    assert_selector '#security-key-feedback', text: 'Credential not found'
    assert_button 'Verify with Device or Security Key', disabled: false
    assert_current_path verify_method_two_factor_authentication_path(type: 'webauthn')
    page.current_window.resize_to(390, 844)
    capture('security-key-server-rejection-narrow')

    visit verify_method_two_factor_authentication_path(type: 'webauthn', locale: :es)
    install_authenticator_prompt
    click_button 'Verify with Device or Security Key'
    assert_selector 'html[data-key-prompt="ready"]', visible: :all
    page.execute_script("window.keyPrompt.reject(new DOMException('User cancelled', 'NotAllowedError'))")
    assert_feedback(:NotAllowedError, locale: :es)
    capture('security-key-cancelled-spanish')

    click_button 'Verify with Device or Security Key'
    finish_prompt(sign_assertion(client, origin.host))
    assert_current_path constituent_portal_dashboard_path
    assert_selector 'h1', text: 'Dashboard'
    assert_equal 1, user.webauthn_credentials.sole.reload.sign_count
    capture('security-key-retry-signed-in')
  ensure
    WebAuthn.configuration.allowed_origins = original_origins
    WebAuthn.configuration.rp_id = original_rp_id
  end

  private

  def feedback(key, locale: :en)
    I18n.t("security_key_verification.feedback.#{key}", locale: locale)
  end

  def assert_feedback(key, locale: :en)
    assert_selector '#security-key-feedback', text: feedback(key, locale: locale)
    assert_button 'Verify with Device or Security Key', disabled: false
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

  def sign_assertion(client, rp_id)
    assert_selector 'html[data-key-prompt="ready"]', visible: :all
    challenge = page.evaluate_script('window.keyPrompt.challenge')
    client.get(challenge: challenge, rp_id: rp_id, user_verified: true, sign_count: 1)
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
