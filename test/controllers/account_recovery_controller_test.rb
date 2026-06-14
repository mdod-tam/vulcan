# frozen_string_literal: true

require 'test_helper'

class AccountRecoveryControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Set up a test user with WebAuthn credentials
    @user = create(:user) # Replaced fixture with factory
    @admin = create(:admin)
    @webauthn_credential = setup_webauthn_credential_for(@user)
  end

  test 'should get new recovery form' do
    get lost_security_key_path
    assert_response :success

    # Check that the form contains the necessary fields
    assert_select 'form'
    assert_select 'input[type=email]'
    assert_select 'textarea' # For details field
    # Form submission could be either button or input
    assert(css_select('button[type=submit]').any? || css_select('input[type=submit]').any?,
           'Form must have a submit button or input')
  end

  test 'should create recovery request for existing user' do
    assert_difference('RecoveryRequest.count', 1) do
      post request_security_key_reset_path, params: {
        email: @user.email,
        details: 'I lost my security key during travel'
      }
    end

    # Check that we're redirected to confirmation page
    assert_redirected_to account_recovery_confirmation_path

    # Verify the recovery request was created correctly
    recovery_request = RecoveryRequest.last
    assert_equal @user.id, recovery_request.user_id
    assert_equal 'pending', recovery_request.status
    assert_equal 'I lost my security key during travel', recovery_request.details
    assert_not_nil recovery_request.ip_address
    assert_not_nil recovery_request.user_agent
  end

  test 'should still redirect to confirmation page for non-existent user' do
    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        email: 'nonexistent@example.com',
        details: 'Test details'
      }
    end

    # Should still redirect to confirmation page for security reasons
    # This prevents email enumeration attacks
    assert_redirected_to account_recovery_confirmation_path
  end

  test 'should create record-only admin notification when request created' do
    assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
      assert_difference -> { Notification.where(action: 'security_key_recovery_requested', recipient: @admin).count }, 1 do
        post request_security_key_reset_path, params: {
          email: @user.email,
          details: 'Test notification'
        }
      end
    end

    notification = Notification.where(action: 'security_key_recovery_requested', recipient: @admin).last
    assert_equal RecoveryRequest.last, notification.notifiable
    assert_equal @user, notification.actor
    assert_equal RecoveryRequest.last.id, notification.metadata['recovery_request_id']
    assert_nil notification.delivery_status
  end

  test 'should not create admin notification for non-existent user' do
    assert_no_difference -> { Notification.where(action: 'security_key_recovery_requested').count } do
      post request_security_key_reset_path, params: {
        email: 'nonexistent@example.com',
        details: 'Test notification'
      }
    end
  end

  test 'should render confirmation page' do
    get account_recovery_confirmation_path
    assert_response :success

    # Check for confirmation message content
    assert_select 'h1', /confirmation|submitted|recovery/i
    assert_select 'a[href=?]', sign_in_path
  end

  test 'should handle missing email parameter' do
    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        details: 'Missing email parameter test'
      }
    end

    # Should still redirect to confirmation page
    assert_redirected_to account_recovery_confirmation_path
  end

  test 'does not require authentication for recovery actions' do
    # Verify that unauthenticated users can access recovery form
    get lost_security_key_path
    assert_response :success

    # Verify that unauthenticated users can submit recovery request
    post request_security_key_reset_path, params: {
      email: @user.email,
      details: 'Unauthenticated access test'
    }
    assert_redirected_to account_recovery_confirmation_path

    # Verify that unauthenticated users can access confirmation page
    get account_recovery_confirmation_path
    assert_response :success
  end

  private

  def setup_webauthn_credential_for(user)
    # Set up WebAuthn for testing
    WebAuthn.configure do |config|
      config.allowed_origins = ['https://example.com']
    end
    fake_client = WebAuthn::FakeClient.new('https://example.com')

    # Create credential options
    credential_options = WebAuthn::Credential.options_for_create(user: { id: user.id, name: user.email })

    # Simulate credential creation with fake client
    credential_hash = fake_client.create(challenge: credential_options.challenge)

    # Create and save a credential for the user
    user.webauthn_credentials.create!(
      external_id: credential_hash['id'],
      public_key: 'dummy_public_key_for_testing',
      nickname: 'Test Key',
      sign_count: 0
    )
  end
end
