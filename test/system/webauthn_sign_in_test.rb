# frozen_string_literal: true

require 'application_system_test_case'

class WebauthnSignInTest < ApplicationSystemTestCase
  include SystemTestAuthentication

  # Browser cleanup workaround.
  def teardown
    super
  rescue NoMethodError => e
    puts "Rescued error during teardown: #{e.class} - #{e.message}"
  end

  test 'registration redirects to welcome page with 2FA setup option' do
    reset_session!

    visit sign_up_path
    assert_text 'Create Account'

    fill_in 'First Name', with: '2FA'
    fill_in 'Last Name', with: 'Tester'
    fill_in 'Email Address', with: 'new_2fa_user@example.com'
    fill_in 'Password', with: 'password123'
    fill_in 'Confirm Password', with: 'password123'
    fill_in 'Phone Number', with: '555-555-5555'
    choose 'Text/SMS' # Registration requires a phone type when a phone is present.

    # The native date field uses YYYY-MM-DD.
    fill_in 'Date of Birth', with: '1990-01-01'

    select 'English', from: 'Language Preference'

    # Email is the default delivery preference, so this case needs no address.

    click_button 'Create Account'

    assert_current_path welcome_path
    assert_text 'Welcome to Maryland Accessible Telecommunications'
    assert_selector 'a', text: 'Set Up Two-Factor Authentication'

    click_link 'Skip and Continue to Dashboard'
    assert_current_path constituent_portal_dashboard_path

    assert_selector '.bg-amber-100', text: /Secure Account/i
  end

  test 'user with WebAuthn gets redirected to verification page' do
    user = create(:constituent, :with_webauthn_credential, :active)
    user.update!(email_verified: true, verified: true, webauthn_id: WebAuthn.generate_user_id)

    visit sign_in_path
    wait_for_network_idle

    within('form[action="/sign_in"]') do
      fill_in 'contact-input', with: user.email
      fill_in 'password-input', with: 'password123'
      click_button 'Sign In'
    end

    wait_for_network_idle

    expected_path = verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_current_path expected_path

    assert_text 'Device or Security Key Verification'
    assert_text 'Use your device (fingerprint or face) or a physical security key to complete sign-in.'

    # This case ends at the verification prompt.
  end

  test 'welcome page links to security key enrollment' do
    user = User.create!(
      email: 'webauthn_test@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      first_name: 'WebAuthn',
      last_name: 'Tester',
      date_of_birth: 30.years.ago,
      phone: '555-555-5555',
      hearing_disability: true,
      type: 'Users::Constituent'
    )

    system_test_sign_in(user)
    visit welcome_path

    assert_selector 'a', text: 'Set Up Two-Factor Authentication'
    click_link 'Set Up Two-Factor Authentication'

    assert_current_path setup_two_factor_authentication_path

    # Match the WebAuthn setup URL to avoid other security links.
    find('a[href*="two_factor_authentication"][href*="credentials/webauthn"]', text: /Security Key|WebAuthn|Add Key/i).click
    assert_current_path new_credential_two_factor_authentication_path(type: 'webauthn')
  end

  test 'security key success page confirms setup for an enrolled user' do
    user = User.create!(
      email: "webauthn_setup_ui_#{SecureRandom.hex(4)}@example.com",
      password: 'password123', password_confirmation: 'password123',
      first_name: 'WebAuthn', last_name: 'SetupUI', type: 'Users::Constituent',
      date_of_birth: 30.years.ago, phone: '555-111-2222'
    )
    user.update!(webauthn_id: WebAuthn.generate_user_id)

    system_test_sign_in(user)
    visit new_credential_two_factor_authentication_path(type: 'webauthn')
    assert_text 'Set up Device or Security Key'

    # The fixture establishes enrollment; SecurityKeyFeedbackTest submits a real attestation.
    create(:webauthn_credential, user: user, nickname: 'My UI Key')

    visit credential_success_two_factor_authentication_path(type: 'webauthn')

    assert_text 'Setup Complete!', wait: 10
    assert_text 'Your Security Key has been successfully set up', wait: 10
    take_screenshot('webauthn-setup-ui-success')

    user.reload
    assert user.webauthn_credentials.exists?(nickname: 'My UI Key')
    assert user.second_factor_enabled?

    visit welcome_path
    assert_current_path constituent_portal_dashboard_path
    assert_selector '.bg-amber-100', text: /Secure Account/i
  end

  test 'WebAuthn verification page displays correctly with proper UI elements' do
    user = create(:constituent, email: "webauthn_ui_test_#{Time.now.to_i}_#{rand(10_000)}@example.com")
    user.update!(email_verified: true, verified: true, webauthn_id: WebAuthn.generate_user_id)

    credential = create(:webauthn_credential, user: user, nickname: 'Login Key')
    assert credential.persisted?

    system_test_sign_in(user, verify_path: verify_method_two_factor_authentication_path(type: 'webauthn'))

    assert_current_path verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_text I18n.t('security_key_verification.page.heading')
    take_screenshot('webauthn-verification-page')

    assert_selector 'button', text: I18n.t('security_key_verification.page.submit')
    assert_text I18n.t('security_key_verification.page.key_description')

    assert_text I18n.t('security_key_verification.page.prepare')
    assert_text I18n.t('security_key_verification.page.click_button')

    # This case inspects button readiness without a WebAuthn submission.
    verification_button = find('button', text: 'Verify with Device or Security Key')
    assert verification_button.visible?
    assert_not verification_button.disabled?

    assert_selector 'a', text: 'Use Authenticator App Instead' if user.totp_credentials.exists?

    assert_selector 'a', text: 'Use Text Message Instead' if user.sms_credentials.verified.exists?

    assert_selector 'a', text: "I've lost my security key"

    # WebauthnPublicFeedbackTest covers assertion failures without hardware.
  end

  test 'security key verification links to the recovery request form' do
    user = create(:user, :confirmed)
    user.update!(webauthn_id: WebAuthn.generate_user_id) if user.webauthn_id.blank?

    credential = create(:webauthn_credential, user: user, nickname: 'Recovery Key')
    assert credential.persisted?

    system_test_sign_in(user)

    assert_current_path verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_text 'Device or Security Key Verification'
    take_screenshot('webauthn-recovery-link-prompt')

    assert_selector 'button', text: I18n.t('security_key_verification.page.submit')
    assert_text I18n.t('security_key_verification.page.key_description')

    assert_text 'I\'ve lost my security key'

    click_link 'I\'ve lost my security key'
    assert_current_path lost_security_key_path
    assert_selector 'form[action="/request_security_key_reset"]'
    assert_selector '#account-recovery-contact'
    take_screenshot('webauthn-recovery-request-form')
  end
end
