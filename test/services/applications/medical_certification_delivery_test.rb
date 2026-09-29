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
      assert_equal 'suppressed', Notification.where(notifiable: @application, action: 'medical_certification_requested').last.delivery_status
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

    def toggle(enabled)
      EmailDelivery::ControlWriter.set(name: EmailDelivery::ALL_CONTROL, enabled: enabled, actor: @admin, operation_id: SecureRandom.uuid)
    end
  end
end
