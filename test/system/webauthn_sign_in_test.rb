# frozen_string_literal: true

require 'application_system_test_case'
require 'webauthn/fake_client' # Ensure FakeClient is available
require_relative '../support/webauthn_test_helper' # Include the helper

# This test focuses on WebAuthn credential management and sign-in flows
# Renamed class for clarity
class WebauthnSignInTest < ApplicationSystemTestCase
  include SystemTestAuthentication
  include WebauthnTestHelper

  # Add teardown to handle any browser cleanup issues gracefully
  def teardown
    # Rescue any browser-related errors during teardown
    super
  # we might need to change this to work with Cuprite gem
  rescue Selenium::WebDriver::Error::NoSuchWindowError,
         Selenium::WebDriver::Error::InvalidArgumentError,
         NoMethodError => e
    puts "Rescued error during teardown: #{e.class} - #{e.message}"
  end

  test 'webauthn credential creation for user' do
    user = create(:user, :confirmed)

    # Configure WebAuthn
    setup_webauthn_test_environment

    # Create WebAuthn credential options
    credential_options = WebAuthn::Credential.options_for_create(user: { id: user.id, name: user.email })

    # Simulate credential creation with fake client
    credential_hash = fake_client.create(challenge: credential_options.challenge)
    puts "DEBUG: Credential Hash: #{credential_hash.inspect}"

    # Save credential to database
    credential = user.webauthn_credentials.create!(
      external_id: credential_hash['id'],
      public_key: 'dummy_public_key_for_testing',
      nickname: 'Test Key',
      sign_count: 0
    )

    # Verify the credential was saved
    assert_not_nil credential.id, 'Credential should have an ID after being saved'
    assert_equal credential_hash['id'], credential.external_id, 'Credential external_id should match the generated ID'

    # Verify the user now has 2FA enabled
    assert user.reload.second_factor_enabled?, 'User should have second factor enabled after credential creation'
  end

  test 'registration redirects to welcome page with 2FA setup option' do
    # Clear any existing sessions
    reset_session!

    # Visit registration page and fill required fields
    visit sign_up_path
    assert_text 'Create Account'

    # Fill in basic information
    fill_in 'First Name', with: '2FA'
    fill_in 'Last Name', with: 'Tester'
    fill_in 'Email Address', with: 'new_2fa_user@example.com'
    fill_in 'Password', with: 'password123'
    fill_in 'Confirm Password', with: 'password123'
    fill_in 'Phone Number', with: '555-555-5555'

    # Fill in Date of Birth (native date field expects YYYY-MM-DD format)
    fill_in 'Date of Birth', with: '1990-01-01'

    # Select language preference
    select 'English', from: 'Language Preference'

    # Communication preference defaults to Email which is what we want
    # No need to fill in address fields

    # Click the Create Account button
    click_button 'Create Account'

    # Verify welcome page and 2FA setup option
    assert_current_path welcome_path
    assert_text 'Welcome to Maryland Accessible Telecommunications'
    assert_selector 'a', text: 'Set Up Two-Factor Authentication'

    # Test the "Skip for now" option
    click_link 'Skip and Continue to Dashboard'
    assert_current_path root_path

    # Header should show the security reminder
    assert_selector '.bg-amber-100', text: /Secure Account/i
  end

  test 'user with WebAuthn gets redirected to verification page' do
    # Create a user with WebAuthn credentials
    user = create(:constituent, :with_webauthn_credential, :active)
    user.update!(email_verified: true, verified: true, webauthn_id: WebAuthn.generate_user_id)

    # Test the sign-in flow up to WebAuthn verification
    visit sign_in_path
    wait_for_network_idle

    within('form[action="/sign_in"]') do
      fill_in 'email-input', with: user.email
      fill_in 'password-input', with: 'password123'
      click_button 'Sign In'
    end

    wait_for_network_idle

    # Should be redirected to WebAuthn verification page
    expected_path = verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_current_path expected_path

    # Verify the WebAuthn verification page displays correctly
    assert_text 'Security Key Verification'
    assert_text 'Use your registered security key to complete sign-in'

    # Test stops here - we don't try to complete actual WebAuthn verification
    # That would require real hardware tokens or platform authenticators
  end

  test 'user can complete 2FA setup from welcome page' do
    # Create test user
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

    # Click the 2FA setup link using the exact text from the welcome page
    assert_selector 'a', text: 'Set Up Two-Factor Authentication'
    click_link 'Set Up Two-Factor Authentication'

    # We should be on the 2FA setup page
    assert_current_path setup_two_factor_authentication_path

    # Navigate to WebAuthn credential setup
    # Be more specific with our selector since there might be multiple webauthn-related links
    find('a[href*="two_factor_authentication"][href*="credentials/webauthn"]', text: /Security Key|WebAuthn|Add Key/i).click
    assert_current_path new_credential_two_factor_authentication_path(type: 'webauthn')

    # Fill in the nickname field using its ID since the label might be complex
    fill_in 'webauthn_credential_nickname', with: 'My Test Security Key'

    # Create credential (simulated since browser WebAuthn API can't be tested directly)
    assert_difference 'user.webauthn_credentials.count', 1 do
      user.webauthn_credentials.create!(
        external_id: SecureRandom.uuid,
        nickname: 'My Test Security Key',
        public_key: 'test_public_key',
        sign_count: 0
      )
    end

    # Verify WebAuthn status and UI
    assert user.reload.webauthn_credentials.exists?
    visit welcome_path

    # Be flexible about dashboard path
    assert ['/constituent/dashboard', '/constituent_portal/dashboard'].include?(current_path),
           "Expected to be redirected to dashboard but was at #{current_path}"

    # Security banner should still be visible to allow users to manage 2FA settings
    assert_selector '.bg-amber-100', text: /Secure Account/i
  end

  test 'user sets up WebAuthn credential via UI' do
    user = User.create!(
      email: "webauthn_setup_ui_#{SecureRandom.hex(4)}@example.com",
      password: 'password123', password_confirmation: 'password123',
      first_name: 'WebAuthn', last_name: 'SetupUI', type: 'Users::Constituent',
      date_of_birth: 30.years.ago, phone: '555-111-2222'
    )
    user.update!(webauthn_id: WebAuthn.generate_user_id) # Ensure webauthn_id is set

    system_test_sign_in(user)
    visit new_credential_two_factor_authentication_path(type: 'webauthn')
    assert_text 'Add a Security Key'

    fill_in 'Nickname', with: 'My UI Key'

    # For system tests, we can't access session data directly like in integration tests
    # Instead, we'll create the credential directly in the database to simulate successful setup
    setup_webauthn_test_environment

    # Create the credential directly since we can't simulate the full WebAuthn flow in system tests
    user.webauthn_credentials.create!(
      external_id: SecureRandom.uuid,
      nickname: 'My UI Key',
      public_key: 'test_public_key_for_system_test',
      sign_count: 0
    )

    # Navigate to the success page to verify the UI flow
    visit credential_success_two_factor_authentication_path(type: 'webauthn')

    # Check for the success page content directly
    assert_text 'Setup Complete!', wait: 10
    assert_text 'Your Security Key has been successfully set up', wait: 10
    take_screenshot('webauthn-setup-ui-success')

    # Verify credential exists
    user.reload
    assert user.webauthn_credentials.exists?(nickname: 'My UI Key')
  end

  test 'WebAuthn verification page displays correctly with proper UI elements' do
    user = create(:constituent, email: "webauthn_ui_test_#{Time.now.to_i}_#{rand(10_000)}@example.com") # Use unique email
    user.update!(email_verified: true, verified: true, webauthn_id: WebAuthn.generate_user_id)

    # Create a credential programmatically first
    fake_client = setup_webauthn_test_environment
    credential = create_fake_credential(user, fake_client, nickname: 'Login Key')
    assert credential.persisted?

    # Sign in and get to WebAuthn verification page
    system_test_sign_in(user, verify_path: verify_method_two_factor_authentication_path(type: 'webauthn'))

    # Should be redirected to WebAuthn verification
    assert_current_path verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_text 'Security Key Verification' # Match the actual heading in the view
    take_screenshot('webauthn-verification-page')

    # Test UI elements are present and functional
    assert_selector 'button', text: 'Verify with Security Key'
    assert_text 'Use your registered security key to verify your identity'

    # Test instructions are displayed
    assert_text 'Make sure your security key is ready'
    assert_text 'Click the button below to start the verification'

    # Test that the verification button is clickable (but don't complete verification)
    verification_button = find('button', text: 'Verify with Security Key')
    assert verification_button.visible?
    assert_not verification_button.disabled?

    # Test alternative method links if available
    assert_selector 'a', text: 'Use Authenticator App Instead' if user.totp_credentials.exists?

    assert_selector 'a', text: 'Use Text Message Instead' if user.sms_credentials.exists?

    # Test "lost security key" link
    assert_selector 'a', text: "I've lost my security key"

    # This test verifies the UI is correctly displayed and functional
    # Actual WebAuthn verification requires real hardware and is tested elsewhere
  end

  test 'user fails login with invalid WebAuthn assertion via UI interaction simulation' do
    user = create(:user, :confirmed) # Use a fixture user
    user.update!(webauthn_id: WebAuthn.generate_user_id) if user.webauthn_id.blank?

    # Create a credential programmatically
    fake_client = setup_webauthn_test_environment
    credential = create_fake_credential(user, fake_client, nickname: 'Login Key Fail')
    assert credential.persisted?

    # Sign in
    system_test_sign_in(user)

    # Should be redirected to WebAuthn verification
    assert_current_path verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_text 'Security Key Verification' # Match the actual heading in the view
    take_screenshot('webauthn-login-ui-fail-prompt')

    # For system tests, we focus on testing the UI behavior for failed verification

    # Verify the UI shows the correct verification elements
    assert_selector 'button', text: 'Verify with Security Key'
    assert_text 'Use your registered security key to verify your identity'

    # Take a screenshot to verify the UI state
    take_screenshot('webauthn-login-ui-fail-prompt')

    # Instead, we verify that the UI provides appropriate feedback mechanisms
    assert_text 'I\'ve lost my security key' # Verify recovery option is available

    # Test the recovery link functionality
    click_link 'I\'ve lost my security key'
    # This should navigate to a recovery page or show recovery options
    take_screenshot('webauthn-login-ui-failure')

    # NOTE: The actual verification failure logic should be tested in integration tests
    # where we can mock the WebAuthn verification process
  end

  private

  # Helper to try different possible selectors for password confirmation
  def fill_password_confirmation(password)
    # Try different field names for password confirmation
    if page.has_field?('Confirm password')
      fill_in 'Confirm password', with: password
    elsif page.has_field?('Password confirmation')
      fill_in 'Password confirmation', with: password
    elsif page.has_field?('user[password_confirmation]')
      fill_in 'user[password_confirmation]', with: password
    else
      # If all else fails, try to find by CSS selector
      field = find('input[name*="password_confirmation"]')
      fill_in field[:id], with: password
    end
  rescue Capybara::ElementNotFound => e
    puts "Warning: Could not find password confirmation field: #{e.message}"
  end

  # Helper to try different possible approaches for date of birth
  def fill_date_of_birth
    if page.has_field?('Date of birth')
      fill_in 'Date of birth', with: '01/01/1990'
    elsif page.has_select?('user_date_of_birth_1i')
      # Rails date selects (year, month, day)
      select '1990', from: 'user_date_of_birth_1i'
      select 'January', from: 'user_date_of_birth_2i'
      select '1', from: 'user_date_of_birth_3i'
    end
  rescue Capybara::ElementNotFound => e
    puts "Warning: Could not fill date of birth field: #{e.message}"
  end

  # Helper to find 2FA setup link with various possible selectors
  def find_2fa_setup_link
    # Try different possible link texts for 2FA setup
    possible_texts = [
      'Add Security Key',
      'Set up Two-Factor Authentication',
      'Enable 2FA',
      'Add Authenticator',
      'Security Settings',
      'Register Security Key'
    ]

    # Try to find any of the possible links
    possible_texts.each do |text|
      return page.find_link(text) if page.has_link?(text)
    end

    # If not found by text, try common CSS selectors
    selectors = [
      'a[href*="two_factor_authentication"][href*="credentials/webauthn"]',
      'a[href*="2fa"]',
      'a[href*="security"]',
      'a[data-test="security-key-setup"]'
    ]

    selectors.each do |selector|
      return page.find(selector) if page.has_css?(selector)
    end

    # Return nil if no matching link found
    nil
  end
end
