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
                       support_email: Policy.get('support_email') || 'mat.program1@maryland.gov')
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
    assert_text I18n.t('portal_self_service.registrations.first_name_label', locale: :es)
    assert_text I18n.t('portal_self_service.registrations.phone_label', locale: :es)
    assert_text I18n.t('portal_self_service.registrations.notification_method_label', locale: :es)
    assert_text I18n.t('portal_self_service.registrations.sign_in_prompt', locale: :es)
    assert_no_text 'Create Account'
    assert_no_text 'First Name'
    assert_no_text 'Notification Method'
    assert_no_text 'Mailed Letter'
    take_screenshot('public-auth-registration-es-mobile', html: true)
    resize_browser_to(width: 1200, height: 800)

    user = create(:constituent, password: 'password123', password_confirmation: 'password123')
    system_test_sign_in(user)
    visit edit_profile_path
    assert_text 'Edit Profile'
    assert_text I18n.t('portal_self_service.profile.on_file')
    take_screenshot('public-auth-profile-edit', html: true)
  end

  private

  def resize_browser_to(width:, height:)
    page.current_window.resize_to(width, height)
  rescue StandardError
    page.driver.browser.resize(width: width, height: height)
  end
end
