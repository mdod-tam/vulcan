# frozen_string_literal: true

require 'test_helper'

module Applications
  class MedicalCertificationDeliveryTest < ActiveJob::TestCase
    setup do
      @admin = create(:admin)
      ensure_system_audit_actor!
      @application = create(:application, medical_provider_email: 'provider@example.com', medical_certification_status: :not_requested)
      @service = MedicalCertificationService.new(application: @application, actor: @admin)
    end

    test 'first and resent provider requests count once and share tracking history and audit identities' do
      2.times do |index|
        travel 6.seconds
        previous = @application.reload.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
        result = assert_difference('Notification.count', 1) do
          assert_difference('ApplicationStatusChange.count', 1) do
            assert_difference("Event.where(action: 'medical_certification_requested').count", 1) do
              @service.request_certification
            end
          end
        end

        assert_predicate result, :success?
        assert_equal index + 1, @application.reload.medical_certification_request_count
        notification = tracking_notification
        history = @application.status_changes.order(:id).last
        audit = Event.where(auditable: @application, action: 'medical_certification_requested').order(:id).last
        state = notification.metadata.fetch('certification_request_state')
        assert_equal index + 1, notification.metadata['request_count']
        assert_equal index, state.dig('previous', 'medical_certification_request_count')
        assert_equal index + 1, state['issued_count']
        assert_equal @application.medical_certification_requested_at, Time.iso8601(state['issued_at'])
        assert_equal previous['medical_certification_status'], history.from_status
        assert_equal 'requested', history.to_status
        assert_equal notification.id, history.metadata['notification_id']
        assert_equal notification.id, audit.metadata['notification_id']
        assert_equal 'email', history.metadata['submission_method']
        assert_equal 'email', audit.metadata['submission_method']
        assert_equal @admin, history.user
        assert_equal @admin, audit.user
      end
    end

    %i[history audit].each do |failed_write|
      test "provider request rolls back state and tracking when #{failed_write} fails" do
        previous = @application.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
        if failed_write == :history
          ApplicationStatusChange.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(ApplicationStatusChange.new))
        else
          AuditEventService.expects(:log).with(has_entries(action: 'medical_certification_requested')).raises(StandardError, 'audit unavailable')
        end

        result = nil
        assert_no_difference ['Notification.count', 'ApplicationStatusChange.count', 'Event.count'] do
          assert_no_enqueued_jobs(only: MedicalCertificationEmailJob) { result = @service.request_certification }
        end

        assert_predicate result, :failure?
        assert_equal previous, @application.reload.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      end
    end

    test 'refusing an older queued request preserves a newer request issued through the service' do
      assert_predicate @service.request_certification, :success?
      older_job = enqueued_jobs.find { |job| job[:job] == MedicalCertificationEmailJob }
      older_notification = tracking_notification
      travel 1.second
      assert_predicate @service.request_certification, :success?
      newer_notification = tracking_notification
      newer_state = @application.reload.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      toggle(false)

      assert_no_difference "Event.where(action: 'medical_certification_request_not_sent').count" do
        assert_no_emails { ActiveJob::Base.execute(older_job) }
      end

      assert_equal newer_state, @application.reload.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      assert_equal 'suppressed', older_notification.reload.delivery_status
      assert_nil newer_notification.reload.metadata['delivery_suppressed']
    end

    test 'early refusal leaves request state and tracking untouched' do
      toggle(false)
      prior = @application.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      assert_no_difference 'Notification.count' do
        assert_no_enqueued_jobs only: MedicalCertificationEmailJob do
          result = @service.request_certification
          assert result.failure?
          assert_equal :suppressed, result.data[:delivery_outcome]
        end
      end
      assert_equal prior, @application.reload.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
    end

    test 'worker refusal restores only the unchanged request owned by that notification' do
      previous = @application.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      assert @service.request_certification.success?
      assert @application.reload.medical_certification_status_requested?
      toggle(false)
      toggle(true)
      assert_no_emails { perform_enqueued_jobs(only: MedicalCertificationEmailJob) }
      assert_equal previous, @application.reload.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      notification = tracking_notification
      assert_equal 'suppressed', notification.delivery_status
      assert_restoration_recorded(notification)
    end

    test 'worker configuration refusal restores the previous certification status timestamp and count with the same history and audit' do
      @application.update!(medical_certification_status: :rejected, medical_certification_requested_at: 3.days.ago.change(usec: 123_456),
                           medical_certification_request_count: 4)
      previous = @application.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      assert @service.request_certification.success?
      EmailDelivery::Policy.stubs(:verify_any).returns(EmailDelivery::Decision.configuration_error(:missing_control))

      assert_no_emails { perform_enqueued_jobs(only: MedicalCertificationEmailJob) }

      assert_equal previous, @application.reload.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      notification = tracking_notification
      assert_equal 'error', notification.delivery_status
      assert_restoration_recorded(notification)
    end

    test 'reprocessing an unsent request does not duplicate its restoration history or audit' do
      assert @service.request_certification.success?
      toggle(false)
      perform_enqueued_jobs(only: MedicalCertificationEmailJob)

      assert_no_difference ['ApplicationStatusChange.count', 'Event.count'] do
        MedicalCertificationService.restore_unsent_request(tracking_notification)
      end
      assert @application.reload.medical_certification_status_not_requested?
    end

    test 'two unsent requests at the same time each record restoration and replay records neither again' do
      audits = Event.where(auditable: @application, action: 'medical_certification_request_not_sent')
      reversals = ApplicationStatusChange.where(application: @application, change_type: 'medical_certification')
                                         .where("metadata->>'reason' = ?", 'delivery_not_sent')
      notifications = []

      freeze_time do
        assert_difference -> { audits.count }, 2 do
          assert_difference -> { reversals.count }, 2 do
            2.times do
              assert @service.request_certification.success?
              notifications << tracking_notification
              toggle(false)
              assert_no_emails { perform_enqueued_jobs(only: MedicalCertificationEmailJob) }
              assert @application.reload.medical_certification_status_not_requested?
              toggle(true)
            end
          end
        end

        assert_no_difference [-> { audits.count }, -> { reversals.count }] do
          MedicalCertificationService.restore_unsent_request(notifications.last)
        end
      end

      assert_equal(notifications.map(&:id), audits.order(:id).map { |event| event.metadata['notification_id'] })
      assert_equal(notifications.map(&:id), reversals.order(:id).map { |change| change.metadata['notification_id'] })
    end

    test 'a request count changed without a timestamp change wins over compensation' do
      assert @service.request_certification.success?
      newer_request_count = @application.reload.medical_certification_request_count + 1
      @application.update!(medical_certification_request_count: newer_request_count)
      issued_at = @application.medical_certification_requested_at
      toggle(false)

      assert_no_difference "Event.where(action: 'medical_certification_request_not_sent').count" do
        perform_enqueued_jobs(only: MedicalCertificationEmailJob)
      end

      assert @application.reload.medical_certification_status_requested?
      assert_equal issued_at, @application.medical_certification_requested_at
      assert_equal newer_request_count, @application.medical_certification_request_count
    end

    test 'an outstanding secure request keeps certification requested even when it predates the unsent email' do
      create(:medical_provider_secure_request_form, application: @application, requested_by: @admin, created_at: 1.hour.ago)
      assert @service.request_certification.success?
      issued_at = @application.reload.medical_certification_requested_at
      toggle(false)

      assert_no_difference "Event.where(action: 'medical_certification_request_not_sent').count" do
        perform_enqueued_jobs(only: MedicalCertificationEmailJob)
      end

      assert @application.reload.medical_certification_status_requested?
      assert_equal issued_at, @application.medical_certification_requested_at
    end

    test 'restoration state and history roll back if its audit cannot be written' do
      assert @service.request_certification.success?
      issued = @application.reload.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      AuditEventService.expects(:log).with(has_entries(action: 'medical_certification_request_not_sent')).raises(StandardError, 'audit unavailable')

      assert_no_difference 'ApplicationStatusChange.count' do
        assert_raises(StandardError) { MedicalCertificationService.restore_unsent_request(tracking_notification) }
      end

      assert_equal issued, @application.reload.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
    end

    test 'a newer DocuSeal request within the same second wins over compensation' do
      assert @service.request_certification.success?
      issued_at = @application.reload.medical_certification_requested_at
      @application.update!(document_signing_requested_at: issued_at + 0.000001)
      toggle(false)
      perform_enqueued_jobs(only: MedicalCertificationEmailJob)
      assert @application.reload.medical_certification_status_requested?
      assert_equal issued_at, @application.medical_certification_requested_at
    end

    private

    def tracking_notification
      Notification.where(notifiable: @application, action: 'medical_certification_requested').order(:id).last
    end

    def assert_restoration_recorded(notification)
      reversal = ApplicationStatusChange.where(application: @application, change_type: 'medical_certification')
                                        .where("metadata->>'reason' = ?", 'delivery_not_sent').sole
      audit = Event.where(auditable: @application, action: 'medical_certification_request_not_sent').sole
      assert_equal 'requested', reversal.from_status
      assert_equal @application.medical_certification_status, reversal.to_status
      assert_equal @admin, reversal.user
      assert_equal notification.id, reversal.metadata['notification_id']
      assert_equal 'delivery_not_sent', audit.metadata['reason']
      assert_equal notification.id, audit.metadata['notification_id']
      assert_equal 'requested', audit.metadata['old_status']
      assert_equal @application.medical_certification_status, audit.metadata['new_status']
      assert_equal @admin, audit.user
    end

    def toggle(enabled)
      EmailDelivery::ControlWriter.set(name: EmailDelivery::ALL_CONTROL, enabled: enabled, actor: @admin, operation_id: SecureRandom.uuid)
    end
  end
end
