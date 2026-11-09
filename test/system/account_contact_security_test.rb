# frozen_string_literal: true

require 'application_system_test_case'
require 'webauthn/fake_client'

class AccountContactSecurityTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    load_seeded_email_templates('contact_change_verification', 'contact_change_notice')
    ActionMailer::Base.deliveries.clear
  end

  test 'password reauthentication and dual email confirmation finish in the requesting browser and sign out' do
    user = create(:constituent, locale: 'en')
    original_email = user.email
    proposed_email = "browser-contact-#{SecureRandom.hex(6)}@example.test"
    sign_in_through_browser(user)
    authority = require_contact_reauthentication(user)
    original_digest = authority.session_token_digest
    assert_selector 'main', count: 1
    click_link translated('reauthentication.cancel')
    assert_current_path edit_profile_path
    visit new_contact_change_path
    assert_current_path new_reauthentication_path(return_to: new_contact_change_path)

    fill_in 'password', with: 'incorrect-password'
    click_button translated('reauthentication.submit')
    assert_text translated('reauthentication.invalid')
    assert_field 'password', with: ''
    assert_selector 'input[name="factor_type"][value="password"]', visible: :all
    assert_selector "input[name='return_to'][value='#{new_contact_change_path}']", visible: :all
    take_screenshot('contact-reauthentication-invalid', html: true, full: true)

    fill_in 'password', with: 'password1234'
    click_button translated('reauthentication.submit')
    assert_current_path new_contact_change_path
    assert_selector 'main', count: 1
    assert_not_equal original_digest, authority.reload.session_token_digest
    assert_equal authority.id, user.sessions.sole.id

    select translated('contact_changes.email'), from: 'contact_change_request_kind'
    select translated('contact_changes.videophone'), from: 'contact_change_request_phone_type'
    fill_in 'contact_change_request_proposed_value', with: 'invalid-email'
    click_button translated('contact_changes.request')
    assert_text translated('contact_changes.invalid')
    assert_select_value 'contact_change_request_kind', 'email'
    assert_select_value 'contact_change_request_phone_type', 'videophone'
    assert_field 'contact_change_request_proposed_value', with: 'invalid-email'
    assert_button translated('contact_changes.request'), disabled: false
    take_screenshot('contact-validation-retains-values', html: true, full: true)

    select translated('contact_changes.phone'), from: 'contact_change_request_kind'
    select translated('contact_changes.voice'), from: 'contact_change_request_phone_type'
    fill_in 'contact_change_request_proposed_value', with: '240-555-0197'
    assert_select_value 'contact_change_request_kind', 'phone'
    assert_select_value 'contact_change_request_phone_type', 'voice'
    select translated('contact_changes.email'), from: 'contact_change_request_kind'
    select translated('contact_changes.text'), from: 'contact_change_request_phone_type'
    fill_in 'contact_change_request_proposed_value', with: proposed_email
    perform_enqueued_jobs do
      click_button translated('contact_changes.request')
      assert_text translated('contact_changes.both_emails')
    end

    change = ContactChangeRequest.where(user_id: user.id).sole
    assert_current_path contact_change_path(change)
    assert_selector 'main', count: 1
    assert change.old_confirmation_required?
    assert_equal 'email', change.kind
    assert_equal 'text', change.phone_type
    assert_equal proposed_email, change.proposed_value
    assert_equal original_email, user.reload.email
    assert_no_button translated('contact_changes.complete')
    expires_at = change.expires_at
    perform_enqueued_jobs do
      click_button translated('contact_changes.resend')
      assert_text translated('contact_changes.both_emails')
    end
    assert_equal expires_at, change.reload.expires_at
    assert_equal original_email, user.reload.email
    take_screenshot('contact-pending-dual-email', html: true, full: true)

    confirm_delivered_email(change, 'old_email', original_email)
    confirm_delivered_email(change, 'new_email', proposed_email)
    assert_equal original_email, user.reload.email
    assert_equal authority.id, user.sessions.sole.id

    assert_no_button translated('contact_changes.complete')
    click_button translated('contact_changes.check_status')
    assert_current_path contact_change_path(change)
    assert_button translated('contact_changes.complete'), disabled: false
    take_screenshot('contact-confirmed-ready-to-complete', html: true, full: true)
    perform_enqueued_jobs do
      click_button translated('contact_changes.complete')
      assert_current_path sign_in_path
    end
    assert_text translated('contact_changes.completed')
    assert_selector 'main', count: 1
    assert_equal proposed_email, user.reload.email
    assert change.reload.completed_at
    assert_empty user.sessions
    take_screenshot('contact-completed-and-signed-out', html: true, full: true)
    visit edit_profile_path
    assert_current_path sign_in_path
  end

  test 'Spanish narrow layout reauthenticates an enrolled authenticator and permits correcting and canceling a voice request' do
    locale = :es
    user = create(:constituent, locale: locale.to_s)
    credential = user.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Mi aplicación', last_used_at: 1.minute.ago)
    sign_in_through_browser(user, locale: locale, credential: credential)
    page.current_window.resize_to(390, 844)
    authority = require_contact_reauthentication(user, locale: locale)
    digest = authority.session_token_digest

    assert_selector 'html[lang=es]'
    assert_select_value 'factor_type', 'totp'
    assert_selector '#code[required]'
    assert_no_selector '[data-reauthentication-target="smsFields"]', visible: true
    take_screenshot('contact-reauthentication-es-narrow', html: true, full: true)
    assert_no_horizontal_overflow

    fill_in 'password', with: 'incorrect-password'
    fill_in 'code', with: next_totp_code(credential)
    click_button translated('reauthentication.submit', locale)
    assert_text translated('reauthentication.invalid', locale)
    assert_select_value 'factor_type', 'totp'
    assert_field 'password', with: ''
    assert_field 'code', with: ''
    assert_selector '#code[required]'
    assert_button translated('reauthentication.submit', locale), disabled: false
    take_screenshot('contact-reauthentication-es-retry', html: true, full: true)

    fill_in 'password', with: 'password1234'
    fill_in 'code', with: next_totp_code(credential)
    click_button translated('reauthentication.submit', locale)
    assert_current_path new_contact_change_path
    assert_not_equal digest, authority.reload.session_token_digest
    assert_selector '#contact_change_request_phone_type[aria-describedby="contact-staff-help"]'
    assert_selector "#contact-staff-help a[href='mailto:#{ProgramContact.support_email}']"
    assert_selector "#contact-staff-help a[href='tel:#{ProgramContact.support_phone}']"

    select translated('contact_changes.phone', locale), from: 'contact_change_request_kind'
    select translated('contact_changes.voice', locale), from: 'contact_change_request_phone_type'
    fill_in 'contact_change_request_proposed_value', with: '123'
    click_button translated('contact_changes.request', locale)
    assert_text translated('contact_changes.invalid', locale)
    assert_select_value 'contact_change_request_kind', 'phone'
    assert_select_value 'contact_change_request_phone_type', 'voice'
    assert_field 'contact_change_request_proposed_value', with: '123'
    assert_button translated('contact_changes.request', locale), disabled: false
    take_screenshot('contact-voice-validation-es-narrow', html: true, full: true)
    assert_no_horizontal_overflow

    select translated('contact_changes.videophone', locale), from: 'contact_change_request_phone_type'
    fill_in 'contact_change_request_proposed_value', with: '240-555-0198'
    perform_enqueued_jobs do
      click_button translated('contact_changes.request', locale)
      assert_text translated('contact_changes.old_active', locale)
    end
    change = ContactChangeRequest.where(user_id: user.id).sole
    assert_equal 'videophone', change.phone_type
    assert change.staff_assistance?
    assert_no_selector 'input[name=code]'
    assert_no_button translated('contact_changes.complete', locale)
    assert_no_button translated('contact_changes.resend', locale)
    assert_no_button translated('contact_changes.check_status', locale)
    assert_link ProgramContact.support_email, href: "mailto:#{ProgramContact.support_email}"
    assert_link ProgramContact.support_phone, href: "tel:#{ProgramContact.support_phone}"
    take_screenshot('contact-staff-assistance-es-narrow', html: true, full: true)
    assert_no_horizontal_overflow

    click_button translated('contact_changes.cancel', locale)
    assert_current_path edit_profile_path
    assert_text translated('contact_changes.canceled', locale)
    assert change.reload.canceled_at
    assert_equal change.notification_email, user.reload.email
    assert_not_equal change.proposed_value, user.phone
    assert_equal authority.id, user.sessions.sole.id
  end

  test 'factor switching and device errors recover through owned SMS proof before a verified SMS contact change' do
    user = create(:constituent, locale: 'en')
    original_phone = user.phone
    sign_in_through_browser(user)
    page.current_window.resize_to(1200, 800)
    authority = user.sessions.sole
    issued_at = authority.reauthenticated_at
    original_digest = authority.session_token_digest
    factors = enroll_browser_test_factors(user)
    assert_equal issued_at, authority.reload.reauthenticated_at
    assert_not authority.freshly_authenticated?(user: user.reload)
    visit new_contact_change_path
    assert_current_path new_reauthentication_path(return_to: new_contact_change_path)
    assert_selector 'main', count: 1

    select translated('reauthentication.sms'), from: 'factor_type'
    select "•••• #{factors[:sms_first].phone_number.last(4)}", from: 'credential_id'
    fill_in 'code', with: '654321'
    select "•••• #{factors[:sms_second].phone_number.last(4)}", from: 'credential_id'
    assert_field 'code', with: ''
    assert_equal '', find('input[name=credential]', visible: :all).value
    assert_selector '#code[required]'
    take_screenshot('reauth-sms-number-switch-clears-proof', html: true, full: true)

    fill_in 'code', with: '654321'
    select translated('reauthentication.webauthn'), from: 'factor_type'
    assert_no_selector '[data-reauthentication-target="codeFields"]', visible: true
    assert_no_selector '#code[required]', visible: :all
    assert_equal '', find_by_id('code', visible: :all).value
    fill_in 'password', with: 'password1234'
    page.execute_script(<<~JS)
      window.contactOriginalCredentialGet = navigator.credentials.get;
      window.contactCredentialCalls = 0;
      navigator.credentials.get = () => {
        window.contactCredentialCalls += 1;
        return Promise.reject(new DOMException('User canceled the device prompt', 'NotAllowedError'));
      };
    JS
    click_button translated('reauthentication.submit')
    assert_selector '[data-reauthentication-target="feedback"]', text: translated('reauthentication.invalid')
    assert_selector '[data-reauthentication-target="feedback"]:focus'
    assert_button translated('reauthentication.submit'), disabled: false
    assert_equal 1, page.evaluate_script('window.contactCredentialCalls')
    assert_equal 0, factors[:webauthn].reload.sign_count
    take_screenshot('reauth-webauthn-device-error-recoverable', html: true, full: true)

    select translated('reauthentication.sms'), from: 'factor_type'
    assert_select_value 'credential_id', factors[:sms_second].id.to_s
    assert_selector '#code[required]'
    assert_equal '', find('input[name=credential]', visible: :all).value
    fill_in 'password', with: 'incorrect-password'
    click_button translated('reauthentication.send_sms')
    assert_selector '[data-reauthentication-target="feedback"]', text: translated('reauthentication.invalid')
    assert_button translated('reauthentication.send_sms'), disabled: false
    assert_empty SmsVerificationAttempt.where(purpose: 'reauthentication')
    take_screenshot('reauth-sms-send-error-retry-ready', html: true, full: true)

    fill_in 'password', with: 'password1234'
    click_button translated('reauthentication.send_sms')
    assert_selector '[data-reauthentication-target="feedback"]', text: translated('reauthentication.sms_sent')
    assert_equal factors[:sms_second].phone_number, SmsVerificationAttempt.find_by!(purpose: 'reauthentication').phone_number
    fill_in 'code', with: '000000'
    click_button translated('reauthentication.submit')
    assert_text translated('reauthentication.invalid')
    assert_select_value 'factor_type', 'sms'
    assert_select_value 'credential_id', factors[:sms_second].id.to_s
    assert_field 'password', with: ''
    assert_field 'code', with: ''
    assert_button translated('reauthentication.submit'), disabled: false
    take_screenshot('reauth-sms-invalid-code-retains-number', html: true, full: true)

    fill_in 'password', with: 'password1234'
    fill_in 'code', with: '123456'
    click_button translated('reauthentication.submit')
    assert_current_path new_contact_change_path
    assert_equal authority.id, user.sessions.sole.id
    assert_not_equal original_digest, authority.reload.session_token_digest
    assert authority.freshly_authenticated?(user: user.reload)

    select translated('contact_changes.phone'), from: 'contact_change_request_kind'
    select translated('contact_changes.text'), from: 'contact_change_request_phone_type'
    fill_in 'contact_change_request_proposed_value', with: '2405550173'
    perform_enqueued_jobs do
      click_button translated('contact_changes.request')
      assert_field 'code', with: ''
    end
    change = ContactChangeRequest.where(user_id: user.id).sole
    assert change.sms?
    assert_equal original_phone, user.reload.phone
    fill_in 'code', with: '000000'
    click_button translated('contact_changes.verify')
    assert_text translated('contact_changes.verification_unavailable')
    assert_field 'code', with: ''
    assert_nil change.reload.new_confirmed_at
    assert_no_button translated('contact_changes.complete')
    take_screenshot('contact-sms-invalid-code-retry', html: true, full: true)

    fill_in 'code', with: '123456'
    click_button translated('contact_changes.verify')
    assert_button translated('contact_changes.complete'), disabled: false
    assert change.reload.new_confirmed_at
    assert_equal original_phone, user.reload.phone
    take_screenshot('contact-sms-confirmed-ready', html: true, full: true)
    perform_enqueued_jobs do
      click_button translated('contact_changes.complete')
      assert_current_path sign_in_path
    end
    assert_equal PhoneNumber.normalize('2405550173'), user.reload.phone
    assert change.reload.completed_at
    assert_empty user.sessions
    assert TotpCredential.exists?(factors[:totp].id)
    assert WebauthnCredential.exists?(factors[:webauthn].id)
    assert_equal factors.values_at(:sms_first, :sms_second).map(&:phone_number).sort, user.sms_credentials.map(&:phone_number).sort
    take_screenshot('contact-sms-completed-factors-retained', html: true, full: true)
  ensure
    page.execute_script(<<~JS)
      if (window.contactOriginalCredentialGet) {
        navigator.credentials.get = window.contactOriginalCredentialGet;
        delete window.contactOriginalCredentialGet;
        delete window.contactCredentialCalls;
      }
    JS
  end

  private

  def enroll_browser_test_factors(user)
    origin = URI.parse(page.current_url)
    client = WebAuthn::FakeClient.new("#{origin.scheme}://#{origin.host}:#{origin.port}")
    registration = WebAuthn::Credential.from_create(client.create(challenge: SecureRandom.urlsafe_base64(32), rp_id: origin.host))
    User.transaction do
      locked = User.lock_for_merge_integrity!(user).fetch(user.id)
      factors = {
        totp: locked.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Existing app', last_used_at: 1.minute.ago),
        sms_first: locked.sms_credentials.create!(phone_number: '2405550171', verified_at: Time.current),
        sms_second: locked.sms_credentials.create!(phone_number: '2405550172', verified_at: Time.current),
        webauthn: locked.webauthn_credentials.create!(
          external_id: registration.id, public_key: registration.public_key,
          nickname: 'Existing security key', sign_count: 0
        )
      }
      locked.advance_security_version!
      factors
    end
  end

  def translated(key, locale = :en)
    I18n.t(key, locale: locale)
  end

  def sign_in_through_browser(user, locale: :en, credential: nil)
    visit sign_in_path(locale: locale)
    fill_in 'contact-input', with: user.email
    fill_in 'password-input', with: 'password1234'
    click_button translated('sessions.form.submit', locale)
    if credential
      assert_current_path verify_method_two_factor_authentication_path(type: 'totp', locale: locale)
      fill_in 'code', with: ROTP::TOTP.new(credential.secret).now
      click_button translated('two_factor_verification.common.submit', locale)
    end
    assert_current_path constituent_portal_dashboard_path, ignore_query: true
  end

  def require_contact_reauthentication(user, locale: :en)
    authority = user.sessions.sole
    authority.update!(reauthenticated_at: 6.minutes.ago)
    visit new_contact_change_path
    assert_current_path new_reauthentication_path(return_to: new_contact_change_path)
    assert_text translated('reauthentication.title', locale)
    authority
  end

  def next_totp_code(credential)
    credential.reload
    ROTP::TOTP.new(credential.secret).at([Time.current, credential.last_used_at + 30.seconds].max)
  end

  def assert_select_value(id, value)
    assert_equal value, find_field(id).value
  end

  def assert_no_horizontal_overflow
    assert page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth'), 'The narrow form must fit without horizontal scrolling'
  end

  def confirm_delivered_email(change, purpose, recipient)
    mail = ActionMailer::Base.deliveries.find do |delivery|
      delivery.to == [recipient] && delivery.body.decoded.include?("/contact_verifications/#{purpose}")
    end
    assert mail, 'Contact confirmation must use the real delivered proof link'
    uri = URI.parse(mail.body.decoded[%r{https?://[^\s<>"]+}])
    field = purpose == 'old_email' ? :old_confirmed_at : :new_confirmed_at
    using_session(:contact_proof_recipient) do
      install_stimulus_error_reporting
      visit uri.request_uri
      assert_text translated('contact_changes.confirm_title')
      assert_selector 'main', count: 1
      assert_nil change.reload.public_send(field), 'Opening a mail link must not confirm it'
      count = Session.count
      click_button translated('contact_changes.verify')
      assert_text translated('contact_changes.confirmed')
      assert_selector 'main', count: 1
      assert change.reload.public_send(field)
      assert_equal count, Session.count, 'Email ownership proof must not create a signed-in session'
      take_screenshot("contact-#{purpose}-confirmed", html: true, full: true)
      visit edit_profile_path
      assert_current_path sign_in_path
    end
  end
end
