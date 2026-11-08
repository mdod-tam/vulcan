# frozen_string_literal: true

require 'test_helper'

module Admin
  class RecoveryRequestsControllerTest < ActionDispatch::IntegrationTest
    setup do
      Current.reset
      @admin = create(:admin)
      @user = create(:constituent)
      @admin_totp = @admin.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Staff app', last_used_at: 1.minute.ago)
      @keys = 2.times.map { create_key(@user) }
      @recovery_request = create(:recovery_request, user: @user)
      sign_in_admin
    end

    test 'queue requires review instead of exposing one click approval' do
      get admin_recovery_requests_path
      assert_response :success
      assert_select 'h1', 'Security Key Recovery Requests'
      assert_select 'a', 'Review identity verification'
      assert_select "form[action='#{approve_admin_recovery_request_path(@recovery_request)}']", count: 0
    end

    test 'fresh staff session sees explicit identity verification fields' do
      get admin_recovery_request_path(@recovery_request)
      assert_response :success
      assert_select 'select[name="recovery_request[verification_method]"]'
      assert_select 'select[name="recovery_request[verification_result]"]'
      assert_select 'input[name="recovery_request[verification_reference]"]'
      assert_select 'input[type="checkbox"][name="recovery_request[identity_check_completed]"]'
    end

    test 'approval records its destructive inventory and preserves other factors' do
      totp = @user.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Retained app', last_used_at: 1.minute.ago)
      sms = @user.sms_credentials.create!(phone_number: @user.phone, verified_at: Time.current)
      target_sessions = 2.times.map { Session.create!(user: @user, ip_address: '127.0.0.1', user_agent: 'Other browser') }
      contact_request = ContactChangeRequest.create!(user: @user, session: target_sessions.first,
                                                     kind: 'email', old_value: @user.email, proposed_value: 'replacement@example.com',
                                                     security_version: @user.security_version, expires_at: 20.minutes.from_now)
      old_version = @user.security_version
      EmailDelivery::NotificationDispatch.any_instance.stubs(:call).returns(true)

      assert_difference -> { Event.where(action: 'security_key_recovery_approved').count }, 1 do
        assert_difference -> { Notification.where(action: 'security_key_recovery_approved').count }, 1 do
          approve
        end
      end

      assert_redirected_to admin_recovery_request_path(@recovery_request)
      assert @recovery_request.reload.approved?
      assert_equal @admin.id, @recovery_request.resolved_by_id
      assert_equal 'verified', @recovery_request.verification_result
      assert_empty @user.reload.webauthn_credentials
      assert_empty @user.sessions
      assert_equal old_version + 1, @user.security_version
      assert contact_request.reload.canceled_at
      assert TotpCredential.exists?(totp.id)
      assert SmsCredential.exists?(sms.id)
      assert @admin.sessions.exists?

      metadata = Event.find_by!(action: 'security_key_recovery_approved', auditable: @recovery_request).metadata
      assert_equal @keys.map(&:id).sort, metadata.fetch('removed_webauthn_credential_ids').sort
      assert_equal 2, metadata.fetch('removed_webauthn_credential_count')
      assert_equal 2, metadata.fetch('revoked_session_count')
      assert_equal({ 'totp' => 1, 'sms' => 1 }, metadata.fetch('retained_factor_counts'))
      assert_equal [contact_request.id], metadata.fetch('canceled_contact_request_ids')
      assert_equal 'CASE-123 approved procedure', metadata.fetch('verification_reference')
      assert_not_includes metadata.to_json, @user.email
      assert_not_includes metadata.to_json, totp.secret
    end

    test 'missing or failed identity verification cannot remove credentials' do
      assert_no_difference -> { @user.webauthn_credentials.count } do
        post approve_admin_recovery_request_path(@recovery_request), params: {
          recovery_request: verification_params.except(:identity_check_completed).merge(verification_result: 'failed')
        }
      end
      assert_response :unprocessable_content
      assert_equal 'pending', @recovery_request.reload.status
      assert_select 'input[name="recovery_request[verification_reference]"][value="CASE-123 approved procedure"]'
      assert_select "form[action='#{approve_admin_recovery_request_path(@recovery_request)}']", count: 1
    end

    test 'old staff authentication must be renewed before approval' do
      travel 6.minutes do
        assert_no_difference -> { @user.webauthn_credentials.count } do
          approve
        end
        assert_redirected_to new_reauthentication_path(return_to: admin_recovery_request_path(@recovery_request))
        assert @recovery_request.reload.pending?
      end
    end

    test 'an administrator cannot approve their own recovery' do
      own_request = create(:recovery_request, user: @admin)
      post approve_admin_recovery_request_path(own_request), params: { recovery_request: verification_params }
      assert_redirected_to admin_recovery_request_path(own_request)
      assert own_request.reload.pending?
      assert_match(/different administrator/i, flash[:alert])
    end

    test 'audit failure rolls back approval credentials sessions and version' do
      target_session = Session.create!(user: @user, ip_address: '127.0.0.1', user_agent: 'Other browser')
      old_version = @user.security_version
      AuditEventService.stubs(:log).returns(nil)

      assert_no_difference -> { Notification.where(action: 'security_key_recovery_approved').count } do
        approve
      end
      assert @recovery_request.reload.pending?
      assert_equal @keys.size, @user.webauthn_credentials.count
      assert Session.exists?(target_session.id)
      assert_equal old_version, @user.reload.security_version
    end

    test 'notice record failure rolls back approval and audit' do
      NotificationService.expects(:create_and_deliver!).raises(ActiveRecord::RecordNotSaved)
      assert_no_difference -> { Event.where(action: 'security_key_recovery_approved').count } do
        approve
      end
      assert @recovery_request.reload.pending?
      assert_equal @keys.size, @user.webauthn_credentials.count
    end

    test 'dispatch failure leaves approved recovery and a durable retryable notice' do
      EmailDelivery::NotificationDispatch.any_instance.stubs(:call).returns(false)
      approve
      assert @recovery_request.reload.approved?
      assert_not WebauthnCredential.exists?(user_id: @user.id)
      notice = @recovery_request.approval_notification
      assert notice.persisted?
      assert notice.metadata.fetch('recovery_delivery_context').fetch('delivery_correlation_id').present?
      assert_match(/is approved/i, flash[:alert])
    end

    test 'a crash after approval commit can retry its original notice without repeating deletion' do
      RecoveryRequests::DispatchApprovalNotice.any_instance.stubs(:call).raises(StandardError)
      approve
      assert @recovery_request.reload.approved?
      assert_match(/could not be confirmed/i, flash[:alert])
      notice = @recovery_request.approval_notification
      new_key = create_key(@user)
      RecoveryRequests::DispatchApprovalNotice.any_instance.unstub(:call)
      EmailDelivery::NotificationDispatch.any_instance.stubs(:call).returns(true)

      assert_no_difference -> { Notification.where(action: 'security_key_recovery_approved').count } do
        assert_no_difference -> { Event.where(action: 'security_key_recovery_approved').count } do
          post retry_notice_admin_recovery_request_path(@recovery_request)
        end
      end
      assert WebauthnCredential.exists?(new_key.id)
      assert_equal notice.id, @recovery_request.reload_approval_notification.id
    end

    test 'submitted notice cannot be dispatched again' do
      EmailDelivery::NotificationDispatch.any_instance.stubs(:call).returns(true)
      approve
      @recovery_request.approval_notification.update!(delivery_status: :submitted)
      EmailDelivery::NotificationDispatch.any_instance.expects(:call).never
      post retry_notice_admin_recovery_request_path(@recovery_request)
      assert_redirected_to admin_recovery_request_path(@recovery_request)
    end

    test 'an ambiguous provider attempt prevents another notice dispatch' do
      EmailDelivery::NotificationDispatch.any_instance.stubs(:call).returns(true)
      approve
      notice = @recovery_request.approval_notification
      notice.update!(delivery_status: :queued)
      EmailDeliveryAttempt.create!(notification: notice, correlation_id: notice.metadata.dig('recovery_delivery_context', 'delivery_correlation_id'),
                                   recipient_key: EmailDeliveryAttempt.recipient_key(@user.email), destination: @user.email,
                                   server_id: 'test-server', mail_action: 'ApplicationNotificationsMailer#security_key_recovery_approved',
                                   state: 'unknown', attempted_at: Time.current)
      EmailDelivery::NotificationDispatch.any_instance.expects(:call).never
      post retry_notice_admin_recovery_request_path(@recovery_request)
      assert_redirected_to admin_recovery_request_path(@recovery_request)
      assert_match(/requires review/i, flash[:notice])
    end

    test 'resolved approval cannot remove newly enrolled credentials on replay' do
      @recovery_request.update!(status: 'approved', resolved_at: Time.current, resolved_by: @admin)
      assert_no_difference -> { @user.webauthn_credentials.count } do
        approve
      end
      assert_redirected_to admin_recovery_request_path(@recovery_request)
      assert_match(/already been resolved/i, flash[:alert])
    end

    test 'public and non administrator callers cannot approve recovery' do
      delete sign_out_path
      approve
      assert_redirected_to sign_in_path
      regular = create(:constituent)
      post sign_in_path, params: { contact: regular.email, password: 'password1234' }
      approve
      assert_redirected_to root_path
      assert @recovery_request.reload.pending?
      assert_equal @keys.size, @user.webauthn_credentials.count
    end

    private

    def sign_in_admin
      post sign_in_path, params: { contact: @admin.email, password: 'password1234' }
      assert_redirected_to verify_method_two_factor_authentication_path(type: 'totp')
      post process_verification_two_factor_authentication_path(type: 'totp'),
           params: { code: ROTP::TOTP.new(@admin_totp.secret).now }, as: :json
      assert_response :success
    end

    def verification_params
      { verification_method: 'staff_assisted_non_sms', verification_result: 'verified',
        verification_reference: 'CASE-123 approved procedure', identity_check_completed: '1' }
    end

    def approve
      post approve_admin_recovery_request_path(@recovery_request), params: { recovery_request: verification_params }
    end

    def create_key(user)
      user.webauthn_credentials.create!(external_id: SecureRandom.uuid, public_key: 'test-public-key',
                                        nickname: 'Security key', sign_count: 0)
    end
  end
end
