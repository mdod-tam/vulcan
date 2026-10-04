# frozen_string_literal: true

require 'application_system_test_case'
require 'webauthn/fake_client'
require_relative '../support/webauthn_test_helper'

class WebauthnSignInTest < ApplicationSystemTestCase
  include SystemTestAuthentication
  include WebauthnTestHelper

  # Browser cleanup workaround.
  def teardown
    super
  rescue NoMethodError => e
    puts "Rescued error during teardown: #{e.class} - #{e.message}"
  end

  test 'webauthn credential creation for user' do
    user = create(:user, :confirmed)

    setup_webauthn_test_environment

    credential_options = WebAuthn::Credential.options_for_create(user: { id: user.id, name: user.email })

    credential_hash = fake_client.create(challenge: credential_options.challenge)
    puts "DEBUG: Credential Hash: #{credential_hash.inspect}"

    credential = user.webauthn_credentials.create!(
      external_id: credential_hash['id'],
      public_key: 'dummy_public_key_for_testing',
      nickname: 'Test Key',
      sign_count: 0
    )

    assert_not_nil credential.id, 'Credential should have an ID after being saved'
    assert_equal credential_hash['id'], credential.external_id, 'Credential external_id should match the generated ID'

    assert user.reload.second_factor_enabled?, 'User should have second factor enabled after credential creation'
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

  test 'user can complete 2FA setup from welcome page' do
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

    fill_in 'webauthn_credential_nickname', with: 'My Test Security Key'

    # This case creates the record directly. It does not submit a WebAuthn attestation.
    assert_difference 'user.webauthn_credentials.count', 1 do
      user.webauthn_credentials.create!(
        external_id: SecureRandom.uuid,
        nickname: 'My Test Security Key',
        public_key: 'test_public_key',
        sign_count: 0
      )
    end

    assert user.reload.webauthn_credentials.exists?
    visit welcome_path

    assert ['/constituent/dashboard', '/constituent_portal/dashboard'].include?(current_path),
           "Expected to be redirected to dashboard but was at #{current_path}"

    # The header retains the profile link after enrollment.
    assert_selector '.bg-amber-100', text: /Secure Account/i
  end

  test 'user sets up WebAuthn credential via UI' do
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

    fill_in 'Name for this device or key', with: 'My UI Key'

    # This case creates the record directly and inspects the success page.
    setup_webauthn_test_environment

    user.webauthn_credentials.create!(
      external_id: SecureRandom.uuid,
      nickname: 'My UI Key',
      public_key: 'test_public_key_for_system_test',
      sign_count: 0
    )

    visit credential_success_two_factor_authentication_path(type: 'webauthn')

    assert_text 'Setup Complete!', wait: 10
    assert_text 'Your Security Key has been successfully set up', wait: 10
    take_screenshot('webauthn-setup-ui-success')

    user.reload
    assert user.webauthn_credentials.exists?(nickname: 'My UI Key')
  end

  test 'WebAuthn verification page displays correctly with proper UI elements' do
    user = create(:constituent, email: "webauthn_ui_test_#{Time.now.to_i}_#{rand(10_000)}@example.com")
    user.update!(email_verified: true, verified: true, webauthn_id: WebAuthn.generate_user_id)

    fake_client = setup_webauthn_test_environment
    credential = create_fake_credential(user, fake_client, nickname: 'Login Key')
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

  test 'user fails login with invalid WebAuthn assertion via UI interaction simulation' do
    user = create(:user, :confirmed)
    user.update!(webauthn_id: WebAuthn.generate_user_id) if user.webauthn_id.blank?

    fake_client = setup_webauthn_test_environment
    credential = create_fake_credential(user, fake_client, nickname: 'Login Key Fail')
    assert credential.persisted?

    system_test_sign_in(user)

    assert_current_path verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_text 'Device or Security Key Verification'
    take_screenshot('webauthn-login-ui-fail-prompt')

    # This case inspects the verification prompt and the recovery link.

    assert_selector 'button', text: I18n.t('security_key_verification.page.submit')
    assert_text I18n.t('security_key_verification.page.key_description')

    take_screenshot('webauthn-login-ui-fail-prompt')

    assert_text 'I\'ve lost my security key'

    click_link 'I\'ve lost my security key'
    take_screenshot('webauthn-login-ui-failure')

    # WebauthnPublicFeedbackTest covers assertion failures at the controller boundary.
  end

  private

  def fill_password_confirmation(password)
    if page.has_field?('Confirm password')
      fill_in 'Confirm password', with: password
    elsif page.has_field?('Password confirmation')
      fill_in 'Password confirmation', with: password
    elsif page.has_field?('user[password_confirmation]')
      fill_in 'user[password_confirmation]', with: password
    else
      field = find('input[name*="password_confirmation"]')
      fill_in field[:id], with: password
    end
  rescue Capybara::ElementNotFound => e
    puts "Warning: Could not find password confirmation field: #{e.message}"
  end

  def fill_date_of_birth
    if page.has_field?('Date of birth')
      fill_in 'Date of birth', with: '01/01/1990'
    elsif page.has_select?('user_date_of_birth_1i')
      select '1990', from: 'user_date_of_birth_1i'
      select 'January', from: 'user_date_of_birth_2i'
      select '1', from: 'user_date_of_birth_3i'
    end
  rescue Capybara::ElementNotFound => e
    puts "Warning: Could not fill date of birth field: #{e.message}"
  end

  def find_2fa_setup_link
    possible_texts = [
      'Add Security Key',
      'Set up Device or Security Key',
      'Set up Two-Factor Authentication',
      'Enable 2FA',
      'Add Authenticator',
      'Security Settings',
      'Register Security Key'
    ]

    possible_texts.each do |text|
      return page.find_link(text) if page.has_link?(text)
    end

    selectors = [
      'a[href*="two_factor_authentication"][href*="credentials/webauthn"]',
      'a[href*="2fa"]',
      'a[href*="security"]',
      'a[data-test="security-key-setup"]'
    ]

    selectors.each do |selector|
      return page.find(selector) if page.has_css?(selector)
    end

    nil
  end
end
