# frozen_string_literal: true

require 'application_system_test_case'

class WebauthnRegistrationTest < ApplicationSystemTestCase
  setup do
    @original_forgery_protection = ApplicationController.allow_forgery_protection
    @original_app_host = Capybara.app_host
    @original_origins = WebAuthn.configuration.allowed_origins
    @original_rp_id = WebAuthn.configuration.rp_id
    ApplicationController.allow_forgery_protection = true
    Capybara.app_host = "http://localhost:#{Capybara.current_session.server.port}"
    WebAuthn.configuration.allowed_origins = [Capybara.app_host]
    WebAuthn.configuration.rp_id = 'localhost'
  end

  teardown do
    ApplicationController.allow_forgery_protection = @original_forgery_protection
    Capybara.app_host = @original_app_host
    WebAuthn.configuration.allowed_origins = @original_origins
    WebAuthn.configuration.rp_id = @original_rp_id
  end

  test 'new account enrolls a real browser credential through Turbo navigation with CSRF protection' do
    sign_up_and_open_enrollment
    fill_in 'Name for this device or key', with: 'My Laptop'

    click_button 'Continue to Key Activation'

    assert_current_path credential_success_two_factor_authentication_path(type: 'webauthn')
    assert_text 'Setup Complete!'
    assert_equal ['My Laptop'], @user.reload.webauthn_credentials.pluck(:nickname)
    take_screenshot('webauthn-registration-success', html: true)
  end

  test 'cancelled authenticator shows an alert and permits enrollment with an edited name' do
    sign_up_and_open_enrollment
    fill_in 'Name for this device or key', with: 'My Laptop'
    page.execute_script <<~JS
      window.originalCredentialCreate = navigator.credentials.create.bind(navigator.credentials);
      navigator.credentials.create = () => Promise.reject(new DOMException('Cancelled', 'NotAllowedError'));
    JS

    click_button 'Continue to Key Activation'

    assert_selector '[role="alert"]', text: 'The operation was cancelled or timed out.'
    assert_field 'Name for this device or key', with: 'My Laptop'
    assert_button 'Continue to Key Activation', disabled: false
    take_screenshot('webauthn-registration-cancelled', html: true)

    page.execute_script 'navigator.credentials.create = window.originalCredentialCreate;'
    fill_in 'Name for this device or key', with: 'Renamed Laptop'
    click_button 'Continue to Key Activation'

    assert_current_path credential_success_two_factor_authentication_path(type: 'webauthn')
    assert_equal ['Renamed Laptop'], @user.reload.webauthn_credentials.pluck(:nickname)
  end

  private

  def sign_up_and_open_enrollment
    visit sign_up_path
    page.execute_script 'window.registrationPageMarker = true;'
    email = "credential-#{SecureRandom.hex(6)}@example.com"
    fill_in 'First Name', with: 'Credential'
    fill_in 'Last Name', with: 'Tester'
    fill_in 'Email Address', with: email
    fill_in 'Password', with: 'Password123!', exact: true
    fill_in 'Confirm Password', with: 'Password123!'
    fill_in 'Date of Birth', with: '01/02/1990'
    select 'English', from: 'Language Preference'
    click_button 'Create Account'
    assert_current_path welcome_path
    @user = User.find_by_email(email)
    assert @user
    click_link 'Set Up Two-Factor Authentication'
    click_on 'Set Up Device or Security Key'
    assert_text 'Set up Device or Security Key'
    assert page.evaluate_script('window.registrationPageMarker'), 'Enrollment should retain the Turbo JavaScript context'
    browser_page = page.driver.browser.page
    browser_page.command('WebAuthn.enable')
    options = {
      protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
      hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true
    }
    browser_page.command('WebAuthn.addVirtualAuthenticator', options: options)
  end
end
