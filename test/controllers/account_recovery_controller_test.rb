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
    assert_select 'input[name=?]', 'contact'
    assert_select 'textarea' # For details field
    # Form submission could be either button or input
    assert(css_select('button[type=submit]').any? || css_select('input[type=submit]').any?,
           'Form must have a submit button or input')
  end

  test 'recovery form uses request locale and recovery-specific copy' do
    get lost_security_key_path(locale: 'es')

    assert_response :success
    assert_select 'strong', I18n.t('portal_self_service.account_recovery.note_label', locale: :es)
    assert_includes response.body, I18n.t('portal_self_service.account_recovery.contact_hint', locale: :es)
    assert_includes response.body, I18n.t('portal_self_service.account_recovery.remember_key_prompt', locale: :es)
    assert_select 'input[name=?][value=?]', 'locale', 'es'
    assert_not_includes response.body, I18n.t('sessions.form.contact_hint', locale: :es)
  end

  test 'should create recovery request for existing user' do
    assert_difference('RecoveryRequest.count', 1) do
      post request_security_key_reset_path, params: {
        contact: @user.email,
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

  test 'recovery request preserves request locale through confirmation' do
    assert_difference('RecoveryRequest.count', 1) do
      post request_security_key_reset_path, params: {
        contact: @user.email,
        details: 'I lost my security key during travel',
        locale: 'es'
      }
    end

    assert_redirected_to account_recovery_confirmation_path(locale: 'es')

    follow_redirect!
    assert_select 'h1', I18n.t('portal_self_service.account_recovery.confirmation_title', locale: :es)
    assert_includes response.body, I18n.t('portal_self_service.account_recovery.confirmation_body', locale: :es)
  end

  test 'should create recovery request for email-backed user via phone contact' do
    assert @user.real_email?
    assert @user.real_phone?

    assert_difference('RecoveryRequest.count', 1) do
      post request_security_key_reset_path, params: {
        contact: @user.phone,
        details: 'Lost key; submitting phone on file for email-backed account'
      }
    end

    assert_redirected_to account_recovery_confirmation_path

    recovery_request = RecoveryRequest.last
    assert_equal @user.id, recovery_request.user_id
    assert_equal 'pending', recovery_request.status
    assert_equal 'Lost key; submitting phone on file for email-backed account', recovery_request.details
  end

  test 'coalesces duplicate pending recovery requests without duplicate admin notifications' do
    create(:recovery_request, user: @user, status: 'pending')

    assert_no_difference('RecoveryRequest.count') do
      assert_no_difference -> { Notification.where(action: 'security_key_recovery_requested').count } do
        post request_security_key_reset_path, params: {
          contact: @user.phone,
          details: 'Repeat while pending'
        }
      end
    end

    assert_redirected_to account_recovery_confirmation_path
  end

  test 'allows new recovery request after prior request is resolved' do
    create(:recovery_request, :approved, user: @user)

    assert_difference('RecoveryRequest.count', 1) do
      post request_security_key_reset_path, params: {
        contact: @user.email,
        details: 'New request after approval'
      }
    end

    assert_redirected_to account_recovery_confirmation_path
    assert_equal 'pending', RecoveryRequest.order(:created_at).last.status
  end

  test 'rate limits new recovery requests per user and ip' do
    old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    AccountRecoveryController::RECOVERY_REQUEST_RATE_LIMIT.times do |i|
      RecoveryRequest.where(user: @user).update_all(status: 'approved', resolved_at: Time.current, resolved_by_id: @admin.id)

      assert_difference('RecoveryRequest.count', 1) do
        post request_security_key_reset_path, params: {
          contact: @user.email,
          details: "Attempt #{i}"
        }
      end
    end

    RecoveryRequest.where(user: @user).update_all(status: 'approved', resolved_at: Time.current, resolved_by_id: @admin.id)

    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        contact: @user.email,
        details: 'Over limit'
      }
    end

    assert_equal 1, Event.where(action: 'security_key_recovery_request_rate_limited', user: @user).count
  ensure
    Rails.cache = old_cache
  end

  test 'rate limits unmatched recovery contacts without storing raw identifier' do
    old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    contact = "unknown-#{SecureRandom.hex(4)}@example.com"

    AccountRecoveryController::RECOVERY_REQUEST_RATE_LIMIT.times do
      assert_no_difference('RecoveryRequest.count') do
        post request_security_key_reset_path, params: {
          contact: contact,
          details: 'Unknown repeated recovery'
        }
      end
    end

    assert_difference -> { Event.where(action: 'security_key_recovery_unmatched_rate_limited').count }, 1 do
      assert_no_difference('RecoveryRequest.count') do
        post request_security_key_reset_path, params: {
          contact: contact,
          details: 'Unknown over limit'
        }
      end
    end

    event = Event.where(action: 'security_key_recovery_unmatched_rate_limited').last
    assert event.metadata['submitted_contact_digest'].present?
    assert_not_includes event.metadata.values.join(' '), contact
  ensure
    Rails.cache = old_cache
  end

  test 'should not create recovery request for phone-only record' do
    phone = '410-555-0210'
    Current.paper_context = true
    begin
      Users::Constituent.create!(
        first_name: 'Phone', last_name: 'OnlyRecovery',
        phone: phone,
        phone_type: 'text',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password123', password_confirmation: 'password123',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        contact: phone,
        details: 'Lost key'
      }
    end

    assert_redirected_to account_recovery_confirmation_path
  end

  test 'should still redirect to confirmation page for non-existent user' do
    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        contact: 'nonexistent@example.com',
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
          contact: @user.email,
          details: 'Test notification'
        }
      end
    end

    notification = Notification.where(action: 'security_key_recovery_requested', recipient: @admin).last
    assert_equal RecoveryRequest.last, notification.notifiable
    assert_equal @user, notification.actor
    assert_equal RecoveryRequest.last.id, notification.metadata['recovery_request_id']
    assert_equal @user.mfa_account_name, notification.metadata['requester_identifier']
    assert_nil notification.delivery_status
  end

  test 'should not create admin notification for non-existent user' do
    assert_no_difference -> { Notification.where(action: 'security_key_recovery_requested').count } do
      post request_security_key_reset_path, params: {
        contact: 'nonexistent@example.com',
        details: 'Test notification'
      }
    end
  end

  test 'should render confirmation page' do
    get account_recovery_confirmation_path
    assert_response :success

    # Check for confirmation message content
    assert_select 'h1', /Recovery Request Submitted/i
    assert_match(/administrator will review your request/i, response.body)
    assert_no_match(/check your email/i, response.body)
    assert_select 'a[href=?]', sign_in_path
  end

  test 'does not leave pending recovery request when admin notification raises' do
    NotificationService::NotificationBuilder.any_instance
                                            .expects(:create_and_deliver!)
                                            .once
                                            .raises(StandardError.new('notification failed'))

    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        contact: @user.email,
        details: 'Notification exception should roll back pending request'
      }
    end

    assert_equal 1, Event.where(action: 'security_key_recovery_request_failed', user: @user).count
    assert_redirected_to account_recovery_confirmation_path
  end

  test 'does not leave pending recovery request when admin notification returns nil' do
    NotificationService::NotificationBuilder.any_instance
                                            .expects(:create_and_deliver!)
                                            .once
                                            .returns(nil)

    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        contact: @user.email,
        details: 'Notification nil return should roll back pending request'
      }
    end

    assert_redirected_to account_recovery_confirmation_path
  end

  test 'handles RecordNotUnique during create as coalesced duplicate pending' do
    RecoveryRequest.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new('duplicate pending key'))

    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        contact: @user.email,
        details: 'Concurrent duplicate pending'
      }
    end

    assert_redirected_to account_recovery_confirmation_path
  end

  test 'should handle missing contact parameter' do
    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        details: 'Missing contact parameter test'
      }
    end

    # Should still redirect to confirmation page
    assert_redirected_to account_recovery_confirmation_path
  end

  test 'ignores legacy email parameter without contact' do
    assert_no_difference('RecoveryRequest.count') do
      post request_security_key_reset_path, params: {
        email: @user.email,
        details: 'Legacy email param'
      }
    end

    assert_redirected_to account_recovery_confirmation_path
  end

  test 'does not require authentication for recovery actions' do
    # Verify that unauthenticated users can access recovery form
    get lost_security_key_path
    assert_response :success

    # Verify that unauthenticated users can submit recovery request
    post request_security_key_reset_path, params: {
      contact: @user.email,
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
