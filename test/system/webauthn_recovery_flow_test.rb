# frozen_string_literal: true

require 'application_system_test_case'
require 'webauthn/fake_client'

class WebauthnRecoveryFlowTest < ApplicationSystemTestCase
  setup do
    @user = FactoryBot.create(:user, email: "recovery-test-#{SecureRandom.hex(4)}@example.com")
    @admin = FactoryBot.create(:admin, email: "admin-test-#{SecureRandom.hex(4)}@example.com")

    setup_webauthn_credential(@user)
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
    FactoryBot.create(:recovery_request, user: @user)

    system_test_sign_in(@admin)

    visit admin_recovery_requests_path

    assert_selector 'h1', text: 'Security Key Recovery Requests'
    assert_text @user.email
    assert_link 'View Details'
  end

  test 'admin can see recovery request details' do
    request = FactoryBot.create(:recovery_request, user: @user)

    system_test_sign_in(@admin)

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

    system_test_sign_in(@admin)

    visit admin_recovery_request_path(request)

    accept_confirm do
      click_button 'Approve Security Key Reset'
    end
    wait_for_turbo

    assert_text 'Security key recovery request approved successfully'

    request.reload
    assert_equal 'approved', request.status
    assert_not_nil request.resolved_at
    assert_equal @admin.id, request.resolved_by_id

    system_test_sign_out

    visit sign_in_path
    fill_in 'contact-input', with: @user.email
    fill_in 'password-input', with: 'password1234'
    click_button 'Sign In'

    # Only proves the WebAuthn prompt is absent. It does not prove sign-in succeeded.
    assert_no_current_path verify_method_two_factor_authentication_path(type: 'webauthn')

    @user.reload
    assert_equal 0, @user.webauthn_credentials.count
  end

  private

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
