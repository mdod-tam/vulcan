# frozen_string_literal: true

require 'test_helper'

module Applications
  class AuditLogBuilderTest < ActiveSupport::TestCase
    setup do
      Application.any_instance.stubs(:require_proof_validations?).returns(false)
      Application.any_instance.stubs(:verify_proof_attachments).returns(true)

      @application = create(:application,
                            :approved,
                            income_proof_status: :approved,
                            residency_proof_status: :approved)

      prepare_application_for_test(@application, stub_attachments: true)

      @admin = create(:admin)
      @user = create(:constituent)

      @status_change = ApplicationStatusChange.create!(
        application: @application,
        user: @admin,
        from_status: 'draft',
        to_status: 'submitted'
      )

      @proof_review = ProofReview.create!(
        application: @application,
        admin: @admin,
        proof_type: 'income',
        status: 'approved',
        reviewed_at: Time.current
      )

      @notification = Notification.create!(
        recipient: @user,
        actor: @admin,
        notifiable: @application,
        action: 'proof_approved',
        read_at: nil
      )

      @event = Event.create!(
        user: @admin,
        action: 'application_created',
        auditable: @application,
        metadata: { application_id: @application.id, initial_status: 'approved' }
      )
    end

    teardown do
      Application.any_instance.unstub(:require_proof_validations?)
      Application.any_instance.unstub(:verify_proof_attachments)
    end

    test 'includes status changes in reverse chronological audit logs' do
      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_not_empty logs

        assert_includes logs, @status_change

        assert_equal logs.map(&:created_at), logs.map(&:created_at).sort.reverse
      end
    end

    test 'returns empty array when application is nil' do
      with_mocked_attachments do
        builder = AuditLogBuilder.new(nil)
        assert_empty builder.build_audit_logs
      end
    end

    test 'returns empty audit logs after a build failure' do
      skip 'Add failure injection and result assertions before enabling this test'
    end

    test 'builds deduplicated audit logs' do
      skip 'Add duplicate-event inputs and deduplication assertions before enabling this test'
    end

    test 'includes user profile changes in audit logs' do
      profile_update_event = Event.create!(
        user: @application.user,
        action: 'profile_updated',
        metadata: {
          user_id: @application.user.id,
          changes: {
            'first_name' => { 'old' => 'Old Name', 'new' => 'New Name' },
            'email' => { 'old' => 'old@example.com', 'new' => 'new@example.com' }
          },
          updated_by: @application.user.id,
          timestamp: Time.current.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, profile_update_event
      end
    end

    test 'includes guardian profile changes for dependent applications' do
      guardian = create(:constituent)
      dependent = create(:constituent)
      dependent_application = create(:application, user: dependent, managing_guardian: guardian)

      guardian_update_event = Event.create!(
        user: guardian,
        action: 'profile_updated_by_guardian',
        metadata: {
          user_id: dependent.id,
          changes: {
            'phone' => { 'old' => '555-123-4567', 'new' => '555-987-6543' }
          },
          updated_by: guardian.id,
          timestamp: Time.current.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(dependent_application)
        logs = builder.build_audit_logs

        assert_includes logs, guardian_update_event
      end
    end

    test 'includes managing guardian profile changes' do
      guardian = create(:constituent)
      dependent = create(:constituent)
      dependent_application = create(:application, user: dependent, managing_guardian: guardian)

      guardian_self_update_event = Event.create!(
        user: guardian,
        action: 'profile_updated',
        metadata: {
          user_id: guardian.id,
          changes: {
            'physical_address_1' => { 'old' => '123 Old St', 'new' => '456 New Ave' }
          },
          updated_by: guardian.id,
          timestamp: Time.current.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(dependent_application)
        logs = builder.build_audit_logs

        assert_includes logs, guardian_self_update_event
      end
    end

    test 'does not include unrelated user profile changes' do
      unrelated_user = create(:constituent)
      unrelated_event = Event.create!(
        user: unrelated_user,
        action: 'profile_updated',
        metadata: {
          user_id: unrelated_user.id,
          changes: {
            'first_name' => { 'old' => 'Unrelated', 'new' => 'User' }
          },
          updated_by: unrelated_user.id,
          timestamp: Time.current.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_not_includes logs, unrelated_event
      end
    end

    test 'profile changes are sorted with other audit logs by created_at' do
      profile_event = Event.create!(
        user: @application.user,
        action: 'profile_updated',
        metadata: {
          user_id: @application.user.id,
          changes: { 'first_name' => { 'old' => 'Old', 'new' => 'New' } },
          updated_by: @application.user.id,
          timestamp: Time.current.iso8601
        },
        created_at: 1.hour.ago
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_equal logs.map(&:created_at), logs.map(&:created_at).sort.reverse

        assert_includes logs, profile_event
      end
    end

    test 'includes secure request issuance notifications in audit logs' do
      provider_info_notification = create(
        :notification,
        recipient: @application.user,
        actor: @admin,
        notifiable: @application,
        action: 'provider_info_requested',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 101,
          'request_batch_id' => 'provider-batch',
          'recipient_channel' => 'email',
          'expires_at' => 2.days.from_now.iso8601
        }
      )
      proof_notification = create(
        :notification,
        recipient: @application.user,
        actor: @admin,
        notifiable: @application,
        action: 'proof_resubmission_requested',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 102,
          'request_batch_id' => 'proof-batch',
          'recipient_channel' => 'email',
          'proof_type' => 'income',
          'expires_at' => 2.days.from_now.iso8601
        }
      )
      cert_notification = create(
        :notification,
        recipient: @application.user,
        actor: @admin,
        notifiable: @application,
        action: 'cert_upload_requested',
        metadata: {
          'application_id' => @application.id,
          'medical_provider_secure_request_form_id' => 103,
          'provider_name' => 'Dr. Provider',
          'provider_email' => 'provider@example.test',
          'requested_channel' => 'email',
          'expires_at' => 2.days.from_now.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, provider_info_notification
        assert_includes logs, proof_notification
        assert_includes logs, cert_notification
      end
    end

    test 'bulk loads secure request delivery owners for the audit view' do
      owner = create(:constituent)
      create(:notification, recipient: @application.user, actor: @admin, notifiable: @application,
                            action: 'provider_info_requested', metadata: { 'delivery_owner_id' => owner.id })

      builder = AuditLogBuilder.new(@application)
      builder.build_audit_logs

      assert_equal owner, builder.delivery_owners_by_id[owner.id]
    end

    test 'includes secure request revocation events in audit logs' do
      provider_info_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'provider_info_request_revoked',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 201,
          'request_batch_id' => 'provider-batch',
          'recipient_name' => @application.user.full_name,
          'recipient_channel' => 'email'
        }
      )
      proof_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'proof_resubmission_request_revoked',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 202,
          'request_batch_id' => 'proof-batch',
          'recipient_name' => @application.user.full_name,
          'recipient_channel' => 'email',
          'proof_type' => 'income'
        }
      )
      cert_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'cert_upload_request_revoked',
        metadata: {
          'application_id' => @application.id,
          'medical_provider_secure_request_form_id' => 203,
          'provider_name' => 'Dr. Provider',
          'provider_email' => 'provider@example.test'
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, provider_info_event
        assert_includes logs, proof_event
        assert_includes logs, cert_event
      end
    end

    test 'includes secure request expiration events in audit logs' do
      proof_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'proof_resubmission_request_expired',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 302,
          'request_batch_id' => 'proof-batch',
          'recipient_name' => @application.user.full_name,
          'recipient_channel' => 'email',
          'proof_type' => 'income'
        }
      )
      cert_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'cert_upload_request_expired',
        metadata: {
          'application_id' => @application.id,
          'medical_provider_secure_request_form_id' => 303,
          'provider_name' => 'Dr. Provider',
          'provider_email' => 'provider@example.test'
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, proof_event
        assert_includes logs, cert_event
      end
    end

    test 'includes secure form submission events in audit logs' do
      proof_event = Event.create!(
        user: @application.user,
        auditable: @application,
        action: 'proof_submitted_via_secure_form',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 402,
          'request_batch_id' => 'proof-submit-batch',
          'proof_type' => 'income'
        }
      )
      cert_event = Event.create!(
        user: ensure_system_audit_actor!,
        auditable: @application,
        action: 'cert_submitted_via_secure_form',
        metadata: {
          'application_id' => @application.id,
          'medical_provider_secure_request_form_id' => 403,
          'provider_name' => 'Dr. Provider',
          'provider_email' => 'provider@example.test'
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, proof_event
        assert_includes logs, cert_event
      end
    end
  end
end
