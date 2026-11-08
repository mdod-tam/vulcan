# frozen_string_literal: true

require 'test_helper'

module Users
  class ContactChangeRecoveryConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      Current.reset
      @user = create(:constituent)
      @admin = create(:admin)
      @admin.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Staff app', last_used_at: 1.minute.ago)
      Current.user = @user
      @old_email = @user.email
      @new_email = "contact-recovery-race-#{SecureRandom.hex(6)}@example.com"
      @record, @token = fresh_session(@user)
      @staff_record, @staff_token = fresh_session(@admin)
      @stale_contact_session = Session.find(@record.id)
      @stale_staff_session = Session.find(@staff_record.id)
      @user.webauthn_credentials.create!(external_id: SecureRandom.uuid, public_key: 'test-key', nickname: 'Lost key', sign_count: 0)
      @change = ContactChange.new(user: @user, actor: @user, session: @record, token: @token)
                             .request!(kind: 'email', proposed_value: @new_email)
      @change.update!(old_confirmed_at: Time.current, new_confirmed_at: Time.current)
      @recovery = create(:recovery_request, user: @user)
      RecoveryRequests::DispatchApprovalNotice.any_instance.stubs(:call).returns(:queued)
    end

    teardown do
      ids = [@user, @admin].compact.map(&:id)
      ContactChangeRequest.where(user_id: ids).delete_all
      WebauthnCredential.where(user_id: ids).delete_all
      TotpCredential.where(user_id: ids).delete_all
      SmsCredential.where(user_id: ids).delete_all
      cleanup_duplicate_review_test_data!(@user, @admin)
      Current.reset
    end

    [%i[recovery complete], %i[contact complete], %i[recovery resend]].each do |first, operation|
      test "#{first} commits first when actual recovery approval races contact #{operation}" do
        ready = Queue.new
        release = Queue.new
        holder_pids = Queue.new
        contender_pids = Queue.new
        contact_result = nil
        recovery_result = nil

        holder = on_own_connection do
          holder_pids << backend_pid
          User.transaction do
            if first == :recovery
              recovery_result = approve_recovery
            else
              contact_result = mutate_contact(operation)
            end
            ready << true
            release.pop
          end
        end
        holder_pid = wait_for_signal(holder_pids, thread: holder)
        wait_for_signal(ready, thread: holder)

        contender = on_own_connection do
          contender_pids << backend_pid
          if first == :recovery
            contact_result = mutate_contact(operation)
          else
            recovery_result = approve_recovery
          end
        end
        confirm_blocked_then_release(wait_for_signal(contender_pids, thread: contender), holder_pid: holder_pid,
                                                                                         release_queue: release, holder_thread: holder, contender_thread: contender)

        assert_equal :approved, recovery_result
        assert_equal(first == :contact ? :completed : :refused, contact_result)
        assert @recovery.reload.approved?
        assert_empty @user.reload.sessions
        assert_empty @user.webauthn_credentials
        assert_equal(first == :contact ? @new_email : @old_email, @user.email)
        assert_equal(first == :contact, @change.reload.completed_at.present?)
        assert @change.canceled_at if first == :recovery
        assert Session.exists?(@staff_record.id)
        assert_equal 1, Notification.where(action: 'security_key_recovery_approved', notifiable: @recovery).count
        assert_equal 1, Event.where(action: 'security_key_recovery_approved', auditable: @recovery).count
      ensure
        release << true if release
        reap_thread(holder, timeout: 10, suppress_errors: true) if holder
        reap_thread(contender, timeout: 10, suppress_errors: true) if contender
      end
    end

    private

    def fresh_session(user)
      record = Session.create!(user: user, ip_address: '127.0.0.1', user_agent: 'Contact recovery race',
                               reauthenticated_at: Time.current, reauthenticated_security_version: user.security_version)
      [record, record.session_token]
    end

    def mutate_contact(operation)
      Current.set(user: @user) do
        ContactChange.new(user: @user, actor: @user, session: @stale_contact_session, token: @token)
                     .public_send("#{operation}!", ContactChangeRequest.find(@change.id))
      end
      :completed
    rescue Session::AuthenticationRequired, ContactChangeRequest::Refused
      :refused
    end

    def approve_recovery
      Current.set(user: @admin) do
        RecoveryRequests::Approve.new(
          recovery_request: RecoveryRequest.find(@recovery.id), actor: @admin,
          session_record: @stale_staff_session, token: @staff_token,
          verification: { verification_method: 'staff_assisted_non_sms', verification_result: 'verified',
                          verification_reference: 'RACE-CASE-123', identity_check_completed: '1' }
        ).call.status
      end
    end
  end
end
