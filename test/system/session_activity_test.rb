# frozen_string_literal: true

require 'application_system_test_case'

class SessionActivitySystemTest < ApplicationSystemTestCase
  test 'constituent typing renews idle time without discarding profile edits' do
    user = create(:constituent)
    sign_in_constituent(user)
    page.current_window.resize_to(1200, 900)
    visit edit_profile_path
    field = find('input[name="users_constituent[first_name]"]')
    field.set('Unfinished')
    session_record, old_activity, absolute_expiry = age_session(user)

    assert_selector '[data-session-activity-target="notice"]', visible: true
    assert_text 'Your session expires in 1 minute'
    assert_equal old_activity, session_record.reload.last_active_at
    assert_equal 'Unfinished', field.value
    take_screenshot('constituent-session-warning', html: true, full: true)

    field.send_keys(:end, ' entry')
    wait_until { session_record.reload.last_active_at > old_activity }
    assert_current_path edit_profile_path
    assert_equal absolute_expiry, session_record.reload.expires_at
    assert_equal 'Unfinished entry', field.value
    assert_no_selector '[data-session-activity-target="notice"]', visible: true
    take_screenshot('constituent-session-renewed', html: true, full: true)
  ensure
    restore_browser_clock
  end

  test 'Spanish constituent can renew from the localized idle warning' do
    user = create(:constituent, locale: :es)
    sign_in_constituent(user)
    page.current_window.resize_to(390, 844)
    assert_selector 'html[lang="es"]', visible: :all
    session_record, old_activity, absolute_expiry = age_session(user)

    assert_selector '[data-session-activity-target="notice"]', visible: true
    assert_text 'Su sesión vence en 1 minuto.'
    assert_button 'Seguir trabajando'
    assert_equal old_activity, session_record.reload.last_active_at
    assert page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth'), 'Spanish warning must fit a narrow screen'
    take_screenshot('spanish-session-warning', html: true, full: true)

    click_button 'Seguir trabajando'
    wait_until { session_record.reload.last_active_at > old_activity }
    assert_current_path constituent_portal_dashboard_path, ignore_query: true
    assert_equal absolute_expiry, session_record.reload.expires_at
    assert_no_selector '[data-session-activity-target="notice"]', visible: true
    take_screenshot('spanish-session-renewed', html: true, full: true)
  ensure
    restore_browser_clock
  end

  test 'vendor can keep working on an unfinished portal profile' do
    user = create(:vendor, :with_terms_accepted)
    credential = user.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Browser authenticator')
    visit sign_in_path
    within '#sign_in_form form' do
      fill_in 'contact-input', with: user.email
      fill_in 'password-input', with: 'password1234'
      click_button 'Sign In'
    end
    assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
    within("form[action='#{process_verification_two_factor_authentication_path(type: 'totp')}']") do
      fill_in 'code', with: ROTP::TOTP.new(credential.secret).now
      click_button I18n.t('two_factor_verification.common.submit')
    end
    assert_current_path vendor_portal_dashboard_path
    page.current_window.resize_to(1200, 900)
    visit edit_vendor_portal_profile_path
    field = find('input[name="users_vendor[business_name]"]')
    field.set('Unfinished business name')
    session_record, old_activity, absolute_expiry = age_session(user)

    assert_selector '[data-session-activity-target="notice"]', visible: true
    assert_text 'Your session expires in 1 minute'
    assert_equal old_activity, session_record.reload.last_active_at
    take_screenshot('vendor-session-warning', html: true, full: true)

    click_button 'Keep working'
    wait_until { session_record.reload.last_active_at > old_activity }
    assert_current_path edit_vendor_portal_profile_path, ignore_query: true
    assert_equal absolute_expiry, session_record.reload.expires_at
    assert_equal 'Unfinished business name', field.value
    assert_no_selector '[data-session-activity-target="notice"]', visible: true
    take_screenshot('vendor-session-renewed', html: true, full: true)
  ensure
    restore_browser_clock
  end

  private

  def sign_in_constituent(user)
    assert_not user.second_factor_enabled?
    visit sign_in_path(locale: user.locale)
    within '#sign_in_form form' do
      fill_in 'contact-input', with: user.email
      fill_in 'password-input', with: 'password1234'
      click_button I18n.t('sessions.form.submit', locale: user.locale)
    end
    assert_current_path constituent_portal_dashboard_path, ignore_query: true
  end

  def age_session(user)
    session_record = user.sessions.order(:id).last
    absolute_expiry = session_record.expires_at
    session_record.update!(last_active_at: 29.minutes.ago)
    old_activity = session_record.last_active_at
    page.execute_script(<<~JS)
      window.originalSessionClock = Date.now;
      Date.now = () => window.originalSessionClock() + 29 * 60 * 1000;
    JS
    [session_record, old_activity, absolute_expiry]
  end

  def restore_browser_clock
    page.execute_script('if (window.originalSessionClock) Date.now = window.originalSessionClock') if page.has_selector?('body', wait: 0)
  end
end
