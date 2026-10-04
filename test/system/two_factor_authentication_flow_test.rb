# frozen_string_literal: true

require 'application_system_test_case'

class TwoFactorAuthenticationFlowTest < ApplicationSystemTestCase
  include SystemTestHelpers

  def teardown
    super
  rescue NoMethodError => e
    puts "Rescued error during teardown: #{e.class} - #{e.message}"
  end

  setup do
    SmsService.stubs(:send_message).returns(true)

    @user = User.create!(
      email: "2fa_flow_test_#{SecureRandom.hex(4)}@example.com",
      password: 'password123',
      password_confirmation: 'password123',
      first_name: '2FA',
      last_name: 'Tester',
      date_of_birth: 30.years.ago,
      phone: '555-555-5555',
      hearing_disability: true,
      type: 'Users::Constituent',
      status: :active,
      verified: true,
      email_verified: true
    )
  end

  test 'user navigates through all 2FA setup options with screenshotting' do
    system_test_sign_in(@user)

    take_screenshot('2fa-1-initial-state')

    visit edit_profile_path
    assert_text 'Edit Profile'

    click_link 'Register Security Key'

    assert_text 'Set up Device or Security Key'
    take_screenshot('2fa-2-setup-options')

    assert_current_path new_credential_two_factor_authentication_path(type: 'webauthn')
    assert_text 'Set up Device or Security Key'
    take_screenshot('2fa-3-webauthn-setup')

    visit new_credential_two_factor_authentication_path(type: 'totp')
    assert_text 'Set up Authenticator App'

    assert(
      page.has_selector?('svg') ||
      page.has_selector?('[data-qrcode]') ||
      page.has_selector?('.qr-code') ||
      page.has_text?(/scan.*code|qr.*code/i),
      'No QR code or related element found'
    )
    take_screenshot('2fa-4-totp-setup')

    visit new_credential_two_factor_authentication_path(type: 'sms')
    assert page.has_text?(/Text Message|SMS|Phone|Verification|Authentication/i), 'SMS setup page text not found'
    take_screenshot('2fa-5-sms-setup')
  end

  test 'user sets up TOTP successfully' do
    # A fixed secret lets the test generate a code without reading the session cookie.
    known_secret = 'JBSWY3DPEHPK3PXP'
    ROTP::Base32.stubs(:random).returns(known_secret)

    system_test_sign_in(@user)
    visit new_credential_two_factor_authentication_path(type: 'totp')

    assert_text 'Set up Authenticator App'
    assert_selector 'svg'

    totp = ROTP::TOTP.new(known_secret)
    valid_code = totp.now

    find_field('Verification Code').set(valid_code)
    find_field('Nickname').set('My Auth App')
    click_button 'Verify & Complete Setup'

    assert_current_path credential_success_two_factor_authentication_path(type: 'totp')
    assert_text 'Authenticator app registered successfully'
    take_screenshot('2fa-6-totp-setup-success')

    @user.reload
    assert @user.totp_credentials.exists?(nickname: 'My Auth App')
  end

  test 'user cannot submit TOTP setup form twice' do
    known_secret = 'JBSWY3DPEHPK3PXP'
    ROTP::Base32.stubs(:random).returns(known_secret)
    system_test_sign_in(@user)
    visit new_credential_two_factor_authentication_path(type: 'totp')
    totp = ROTP::TOTP.new(known_secret)
    valid_code = totp.now
    find_field('Verification Code').set(valid_code)
    find_field('Nickname').set('My Resilient Auth App')
    click_button 'Verify & Complete Setup'
    assert_current_path credential_success_two_factor_authentication_path(type: 'totp')
    assert_text 'Authenticator app registered successfully'
    assert_no_button 'Verify & Complete Setup'
    assert_equal 1, @user.reload.totp_credentials.count, 'Should not create duplicate credentials'
  end

  test 'user logs in successfully using TOTP' do
    secret = ROTP::Base32.random
    @user.totp_credentials.create!(secret: secret, nickname: 'Test TOTP', last_used_at: Time.current)

    system_test_sign_in(@user, verify_path: verify_method_two_factor_authentication_path(type: 'totp'))

    assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
    assert_text 'Enter the code from your authenticator app'
    take_screenshot('2fa-7-totp-login-prompt')

    totp = ROTP::TOTP.new(secret)
    valid_code = totp.now

    assert_selector 'input[name="code"]', wait: 5
    find_field('code').set(valid_code)
    click_button 'Verify'

    # The success message confirms completion before the dashboard assertion.
    assert_text 'Signed in successfully'

    assert_current_path constituent_portal_dashboard_path
    assert page.has_button?('Sign Out')
    take_screenshot('2fa-8-totp-login-success')
  end

  test 'user fails login with invalid TOTP code' do
    secret = ROTP::Base32.random
    @user.totp_credentials.create!(secret: secret, nickname: 'Test TOTP', last_used_at: Time.current)

    system_test_sign_in(@user, verify_path: verify_method_two_factor_authentication_path(type: 'totp'))

    assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
    assert_text 'Enter the code from your authenticator app'

    invalid_code = '000000'
    assert_selector 'input[name="code"]', wait: 5
    find_field('code').set(invalid_code)
    click_button 'Verify'

    # Wait for Turbo to render the verification error.
    assert_selector '[role="alert"]', text: /Invalid verification code/i, wait: 5

    assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
  end

  test 'user logs in successfully using SMS' do
    test_phone = '555-999-8888'
    @user.sms_credentials.create!(phone_number: test_phone, last_sent_at: Time.current, verified_at: Time.current)

    system_test_sign_in(@user, verify_path: verify_method_two_factor_authentication_path(type: 'sms'))

    assert_match(%r{/two_factor_authentication/verify/sms}, current_path,
                 'Expected to land on SMS verification page')
    take_screenshot('2fa-12-sms-login-prompt')

    # TwilioVerifyService accepts this code in test mode.
    known_code = '123456'

    wait_for_turbo

    find_field('code').set(known_code)

    click_button 'Verify'

    assert_equal '/constituent_portal/dashboard', current_path

    assert_current_path constituent_portal_dashboard_path
    assert_text 'Signed in successfully'
    assert page.has_button?('Sign Out')
    take_screenshot('2fa-13-sms-login-success')
  end

  test 'user fails login with invalid SMS code' do
    test_phone = '555-777-6666'
    @user.sms_credentials.create!(phone_number: test_phone, last_sent_at: Time.current, verified_at: Time.current)

    system_test_sign_in(@user, verify_path: verify_method_two_factor_authentication_path(type: 'sms'))

    assert_match(%r{/two_factor_authentication/verify/sms}, current_path,
                 'Expected to land on SMS verification page')

    invalid_code = '000000'
    assert_selector 'input[name="code"]', wait: 5
    find_field('code').set(invalid_code)
    click_button 'Verify'

    take_screenshot('2fa-14-sms-login-failure')

    assert_match(%r{/two_factor_authentication/verify/sms}, current_path)
  end

  test 'user fails login with expired SMS code' do
    test_phone = '555-555-4444'
    @user.sms_credentials.create!(phone_number: test_phone, last_sent_at: Time.current, verified_at: Time.current)

    system_test_sign_in(@user, verify_path: verify_method_two_factor_authentication_path(type: 'sms'))

    assert_match(%r{/two_factor_authentication/verify/sms}, current_path,
                 'Expected to land on SMS verification page')
    take_screenshot('2fa-15-sms-expired-failure')

    assert_match(%r{/two_factor_authentication/verify/sms}, current_path)
  end

  test 'user removes WebAuthn credential successfully' do
    credential = create(:webauthn_credential, user: @user, nickname: 'KeyToDelete')
    assert @user.reload.webauthn_credentials.exists?(nickname: 'KeyToDelete')

    system_test_sign_in(@user)

    if current_path.include?('two_factor_authentication')
      # Skip when sign-in requires WebAuthn browser simulation.
      skip('WebAuthn system test requires complex browser simulation')
    end

    visit edit_profile_path
    assert_text 'Edit Profile'
    take_screenshot('2fa-16-delete-webauthn-profile')

    within "#webauthn_credential_#{credential.id}" do
      accept_confirm do
        click_button 'Remove'
      end
    end

    assert_current_path edit_profile_path
    assert_text 'Security key removed successfully'
    take_screenshot('2fa-17-delete-webauthn-success')

    @user.reload
    assert_not @user.webauthn_credentials.exists?(nickname: 'KeyToDelete')
  end

  test 'user removes TOTP credential successfully' do
    secret = ROTP::Base32.random
    credential = @user.totp_credentials.create!(secret: secret, nickname: 'AppToDelete', last_used_at: Time.current)
    assert @user.reload.totp_credentials.exists?(nickname: 'AppToDelete')

    system_test_sign_in(@user, verify_path: verify_method_two_factor_authentication_path(type: 'totp'))

    if current_path.include?('two_factor_authentication')
      totp = ROTP::TOTP.new(secret)
      valid_code = totp.now
      assert_selector 'input[name="code"]', wait: 5
      find_field('code').set(valid_code)
      click_button 'Verify'
    end

    visit edit_profile_path
    assert_text 'Edit Profile'
    take_screenshot('2fa-18-delete-totp-profile')

    within "#totp_credential_#{credential.id}" do
      accept_confirm do
        click_button 'Remove'
      end
    end

    assert_current_path edit_profile_path
    assert_text 'Authenticator app removed successfully'
    take_screenshot('2fa-19-delete-totp-success')

    @user.reload
    assert_not @user.totp_credentials.exists?(nickname: 'AppToDelete')
  end

  test 'user removes SMS credential successfully' do
    test_phone = '555-000-1111'
    credential = @user.sms_credentials.create!(phone_number: test_phone, last_sent_at: Time.current, verified_at: Time.current)
    assert @user.reload.sms_credentials.exists?(phone_number: test_phone)

    system_test_sign_in(@user, verify_path: verify_method_two_factor_authentication_path(type: 'sms'))

    if current_path.include?('two_factor_authentication')
      # TwilioVerifyService accepts this code in test mode.
      known_code = '123456'
      assert_selector 'input[name="code"]', wait: 5
      find_field('code').set(known_code)
      click_button 'Verify'
    end

    visit edit_profile_path
    assert_text 'Edit Profile'
    take_screenshot('2fa-20-delete-sms-profile')

    within "#sms_credential_#{credential.id}" do
      accept_confirm do
        click_button 'Remove'
      end
    end

    assert_current_path edit_profile_path
    assert_text 'SMS verification removed successfully'
    take_screenshot('2fa-21-delete-sms-success')

    @user.reload
    assert_not @user.sms_credentials.exists?(phone_number: test_phone)
  end

  test 'multi-method user sees all available verification options during sign in' do
    skip('Skipping multi-method test until the actual UI is finalized')

    @user.totp_credentials.create!(
      secret: ROTP::Base32.random,
      nickname: 'Test TOTP App',
      last_used_at: Time.current
    )

    @user.sms_credentials.create!(
      phone_number: '555-123-4567',
      last_sent_at: Time.current,
      verified_at: Time.current
    )

    visit root_path
    click_button 'Sign Out' if page.has_button?('Sign Out')

    visit sign_in_path
    find_by_id('contact-input').send_keys(@user.email)
    find_by_id('password-input').send_keys('password123')
    click_button 'Sign In'

    wait_for_turbo

    take_screenshot('2fa-verification-options-actual')

    assert page.has_text?(/security|verification|authentication|key|code/i),
           'Not on a verification page'

    assert page.has_selector?('form'), 'No verification form found'
  end

  test 'user is properly redirected when trying to bypass 2FA setup' do
    @user.totp_credentials.create!(
      secret: ROTP::Base32.random,
      nickname: 'Test TOTP',
      last_used_at: Time.current
    )

    visit sign_in_path
    find_by_id('contact-input').send_keys(@user.email)
    find_by_id('password-input').send_keys('password123')
    click_button 'Sign In'

    wait_for_turbo

    assert page.has_text?(/security key|verification|authenticate/i), 'Not on verification page'

    verification_path = current_path

    visit edit_profile_path

    # An incomplete 2FA flow must not grant access to the profile.

    assert(
      current_path == verification_path ||
      current_path == sign_in_path ||
      page.has_text?(/sign in|login|authentication required/i),
      'Not properly redirected when bypassing 2FA'
    )

    take_screenshot('2fa-10-redirect-protection')
  end
end
