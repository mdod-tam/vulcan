# frozen_string_literal: true

require 'application_system_test_case'

class PublicAuthEvidenceTest < ApplicationSystemTestCase
  test 'public auth and profile visible states have current screenshot evidence' do
    visit sign_in_path
    assert_text I18n.t('sessions.title')
    take_screenshot('public-auth-sign-in', html: true)

    visit new_password_path
    assert_text I18n.t('portal_self_service.account_access.title')
    take_screenshot('public-auth-account-access', html: true)

    page.execute_script(<<~JS, "unknown-#{SecureRandom.hex(4)}@example.com")
      var input = document.querySelector('#account-access-contact');
      input.value = arguments[0];
      input.dispatchEvent(new Event('input', { bubbles: true }));
      HTMLFormElement.prototype.submit.call(document.querySelector('form[action="/password"]'));
    JS
    wait_until { current_path == sign_in_path }
    assert_text I18n.t('portal_self_service.account_access.confirmation',
                       support_email: ProgramContact.support_email,
                       support_phone: ProgramContact.support_phone_display)
    take_screenshot('public-auth-account-access-confirmation', html: true)

    visit lost_security_key_path
    assert_text I18n.t('portal_self_service.account_recovery.title')
    take_screenshot('public-auth-account-recovery', html: true)

    visit account_recovery_confirmation_path
    assert_text I18n.t('portal_self_service.account_recovery.confirmation_title')
    take_screenshot('public-auth-recovery-confirmation', html: true)

    resize_browser_to(width: 390, height: 844)
    visit sign_up_path(locale: 'es')
    assert_text I18n.t('portal_self_service.registrations.title', locale: :es)
    assert_text I18n.t('registration_verification.introduction', locale: :es)
    assert_no_selector 'input[type=password]'
    assert_no_selector 'input[name="user[phone]"]'
    assert_no_text 'Create Account'
    assert_no_text 'First Name'
    assert_no_text 'Notification Method'
    assert_no_text 'Mailed Letter'
    take_screenshot('public-auth-registration-es-mobile', html: true)
    resize_browser_to(width: 1200, height: 800)

    user = create(:constituent, password: 'password1234', password_confirmation: 'password1234')
    system_test_sign_in(user)
    visit edit_profile_path
    assert_text 'Edit Profile'
    assert_text I18n.t('contact_changes.title')
    assert_no_selector 'input[name="user[email]"], input[name="user[phone]"]'
    assert_button 'Update Profile', disabled: false
    take_screenshot('public-auth-profile-edit', html: true)

    visit edit_password_path
    fill_in 'Current Password', with: 'wrong-password-1234'
    fill_in 'New Password', with: 'NewValid*Password123'
    fill_in 'Confirm New Password', with: 'NewValid*Password123'
    click_button 'Change Password'
    assert_selector '[data-testid="flash-alert"]', text: 'Current password is incorrect.', count: 1
    take_screenshot('public-auth-password-change-failure', html: true)

    system_test_sign_out
    install_stimulus_error_reporting
    vendor = create(:vendor)
    credential = vendor.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Vendor app', last_used_at: 1.minute.ago)
    visit sign_in_path
    fill_in 'contact-input', with: vendor.email
    fill_in 'password-input', with: 'password1234'
    click_button I18n.t('sessions.form.submit')
    assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
    fill_in 'code', with: ROTP::TOTP.new(credential.secret).now
    click_button I18n.t('two_factor_verification.common.submit')
    assert_current_path vendor_portal_dashboard_path
    visit edit_vendor_portal_profile_path
    assert_no_selector 'input[name="users_vendor[email]"], input[name="users_vendor[phone]"]'
    within 'section[aria-labelledby="vendor-contact-title"]' do
      assert_text vendor.email
      assert_link I18n.t('contact_changes.title'), href: new_contact_change_path
    end
    take_screenshot('vendor-profile-verified-contact-entry', html: true, full: true)
    within('section[aria-labelledby="vendor-contact-title"]') { click_link I18n.t('contact_changes.title') }
    assert_current_path new_contact_change_path
    assert_field 'contact_change_request_proposed_value'
  end

  private

  def resize_browser_to(width:, height:)
    page.current_window.resize_to(width, height)
  rescue StandardError
    page.driver.browser.resize(width: width, height: height)
  end
end
