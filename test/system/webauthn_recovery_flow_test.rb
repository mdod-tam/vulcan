# frozen_string_literal: true

require 'application_system_test_case'
require 'webauthn/fake_client'

class WebauthnRecoveryFlowTest < ApplicationSystemTestCase
  setup do
    @user = FactoryBot.create(:constituent, email: "recovery-test-#{SecureRandom.hex(4)}@example.com")
    @admin = FactoryBot.create(:admin, email: "admin-test-#{SecureRandom.hex(4)}@example.com")

    setup_webauthn_credential(@user)
    @admin_totp = @admin.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Staff app', last_used_at: 1.minute.ago)
  end

  test 'recovery link appears on webauthn authentication page' do
    visit sign_in_path
    fill_in 'contact-input', with: @user.email
    fill_in 'password-input', with: 'password1234'
    click_button 'Sign In'

    assert_text 'Use your device (fingerprint or face) or a physical security key to complete sign-in.'

    assert_link "I've lost my security key"
    assert_selector "a[href='#{lost_security_key_path}']"
  end

  test 'recovery request form contains required fields' do
    visit lost_security_key_path

    assert_selector 'h1', text: 'Security Key Recovery'
    assert_field 'contact'
    assert_field 'details'
    assert_button 'Submit Recovery Request'
  end

  test 'admin can see recovery requests' do
    request = FactoryBot.create(:recovery_request, user: @user)

    sign_in_admin

    visit admin_user_path(@user)
    assert_link 'Security-key recovery requests', href: admin_recovery_requests_path
    take_screenshot('security-key-recovery-staff-entry', html: true, full: true)
    click_link 'Security-key recovery requests'

    assert_selector 'h1', text: 'Security Key Recovery Requests'
    assert_text @user.email
    assert_link 'Review identity verification'
    take_screenshot('security-key-recovery-queue', html: true, full: true)
    within('li', text: @user.email) { click_link 'Review identity verification' }
    assert_current_path admin_recovery_request_path(request)
    assert_selector 'h1', text: 'Security Key Recovery Request'
    assert_text 'Verify identity before approval'
    take_screenshot('security-key-recovery-review-detail', html: true, full: true)
  end

  test 'admin can see recovery request details' do
    request = FactoryBot.create(:recovery_request, user: @user)

    sign_in_admin

    visit admin_recovery_request_path(request)

    assert_selector 'h1', text: 'Security Key Recovery Request'
    assert_text @user.email
    assert_button 'Approve Security Key Reset'

    assert_text 'Security Keys'
  end

  test 'user can submit recovery request and see confirmation page' do
    visit lost_security_key_path

    fill_in 'contact', with: @user.email
    fill_in 'details', with: 'I lost my security key during travel.'
    click_button 'Submit Recovery Request'

    assert_current_path account_recovery_confirmation_path

    assert_selector 'h1', text: 'Recovery Request Received'
    assert_text 'If the information provided matches a portal account'
    assert_link 'Back to sign in'

    assert RecoveryRequest.exists?(user_id: @user.id)
  end

  test 'admin can approve recovery request and user can login without 2FA afterwards' do
    request = FactoryBot.create(:recovery_request, user: @user)

    assert @user.webauthn_credentials.exists?

    sign_in_admin

    visit admin_recovery_request_path(request)
    complete_verification_record
    take_screenshot('security-key-recovery-verification', html: true, full: true)

    accept_confirm do
      click_button 'Approve Security Key Reset'
    end
    wait_for_turbo

    assert_text 'Security-key recovery approved.'
    take_screenshot('security-key-recovery-approved', html: true, full: true)

    request.reload
    assert_equal 'approved', request.status
    assert_not_nil request.resolved_at
    assert_equal @admin.id, request.resolved_by_id

    system_test_sign_out

    visit sign_in_path
    fill_in 'contact-input', with: @user.email
    fill_in 'password-input', with: 'password1234'
    click_button 'Sign In'

    assert_current_path constituent_portal_dashboard_path

    @user.reload
    assert_equal 0, @user.webauthn_credentials.count
  end

  test 'staff verification errors preserve input and allow correction before approval' do
    request = FactoryBot.create(:recovery_request, user: @user)
    sign_in_admin
    visit admin_recovery_request_path(request)
    complete_verification_record(reference: '   ')
    accept_confirm { click_button 'Approve Security Key Reset' }
    assert_text 'Complete the verification record'
    assert_selector '#recovery_request_verification_method option:checked', text: 'Staff-assisted identity check (no SMS)'
    assert_selector '#recovery_request_verification_result option:checked', text: 'Identity verified'
    assert_checked_field 'I completed the approved non-SMS identity check and verified that this request belongs to this account owner.'
    take_screenshot('security-key-recovery-verification-error', html: true, full: true)
    uncheck 'recovery_request_identity_check_completed'
    assert_unchecked_field 'recovery_request_identity_check_completed'
    assert_not find_by_id('recovery_request_identity_check_completed').evaluate_script('this.checkValidity()')
    assert_selector 'input[type=hidden][name="recovery_request[identity_check_completed]"][value="0"]', visible: :all
    check 'recovery_request_identity_check_completed'
    assert_checked_field 'recovery_request_identity_check_completed'
    take_screenshot('security-key-recovery-verification-corrected-checkbox', html: true, full: true)
    fill_in 'Nonsecret case or procedure reference', with: 'CASE-123'
    dismiss_confirm { click_button 'Approve Security Key Reset' }
    assert request.reload.pending?
    assert @user.webauthn_credentials.exists?
    assert_button 'Approve Security Key Reset', disabled: false
    take_screenshot('security-key-recovery-approval-cancelled', html: true, full: true)
    EmailDelivery::NotificationDispatch.any_instance.stubs(:call).raises(IOError, 'Simulated queue failure')
    accept_confirm { click_button 'Approve Security Key Reset' }
    assert_text 'Security-key recovery is approved and sessions were revoked.'
    assert request.reload.approved?
    assert_equal 0, @user.webauthn_credentials.count
    take_screenshot('security-key-recovery-notice-failed', html: true, full: true)
    notification_id = request.approval_notification.id
    version = @user.reload.security_version
    events = Event.where(action: 'security_key_recovery_approved', auditable: request).pluck(:id)
    EmailDelivery::NotificationDispatch.any_instance.unstub(:call)
    click_button 'Retry recovery notice'
    assert_text 'The recovery notice is queued. Approval was not repeated.'
    assert request.reload.approved?
    assert_equal notification_id, request.reload_approval_notification.id
    assert_equal version, @user.reload.security_version
    assert_equal events, Event.where(action: 'security_key_recovery_approved', auditable: request).pluck(:id)
    assert_equal 0, @user.webauthn_credentials.count
    take_screenshot('security-key-recovery-notice-retried', html: true, full: true)
  end

  private

  def sign_in_admin
    visit sign_in_path
    fill_in 'contact-input', with: @admin.email
    fill_in 'password-input', with: 'password1234'
    click_button 'Sign In'
    assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
    fill_in 'code', with: ROTP::TOTP.new(@admin_totp.secret).now
    click_button I18n.t('two_factor_verification.common.submit')
    assert_current_path admin_dashboard_path
  end

  def complete_verification_record(reference: 'CASE-123')
    select 'Staff-assisted identity check (no SMS)', from: 'Verification method'
    select 'Identity verified', from: 'Verification result'
    fill_in 'Nonsecret case or procedure reference', with: reference
    check 'I completed the approved non-SMS identity check and verified that this request belongs to this account owner.'
  end

  def setup_webauthn_credential(user)
    WebAuthn.configure do |config|
      config.allowed_origins = ['https://example.com']
    end
    fake_client = WebAuthn::FakeClient.new('https://example.com')

    credential_options = WebAuthn::Credential.options_for_create(user: { id: user.id, name: user.email })
    credential_hash = fake_client.create(challenge: credential_options.challenge)

    user.webauthn_credentials.create!(
      external_id: credential_hash['id'],
      public_key: 'dummy_public_key_for_testing',
      nickname: 'Test Key',
      sign_count: 0
    )
  end
end
