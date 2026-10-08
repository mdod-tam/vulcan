# frozen_string_literal: true

require 'test_helper'

module Applications
  class DcfAutoRequestTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include ConcurrencyTestHelper

    self.use_transactional_tests = false

    setup do
      @admin = create(:admin)
      @application = create(:application, :in_progress, :income_not_required, medical_provider_email: 'provider@example.test')
      @user = @application.user
      %i[id_proof residency_proof].each do |proof|
        @application.public_send(proof).attach(io: StringIO.new('proof'), filename: "#{proof}.pdf", content_type: 'application/pdf')
      end
      @application.update_columns(id_proof_status: Application.id_proof_statuses[:approved],
                                  residency_proof_status: Application.residency_proof_statuses[:approved],
                                  medical_certification_status: Application.medical_certification_statuses[:not_requested])
      @flag = FeatureFlag.find_or_create_by!(name: 'dcf_auto_request_certification') { |flag| flag.enabled = false }
      @original_flag = @flag.enabled
      @control = FeatureFlag.find_by!(name: EmailDelivery.category_control('certification'))
      @original_control = @control.slice(:enabled, :delivery_generation)
      load_seeded_email_templates('medical_provider_request_certification')
      clear_enqueued_jobs
      Current.user = @admin
    end

    teardown do
      @flag.update_columns(enabled: @original_flag) if @flag&.persisted?
      @control.update_columns(@original_control) if @original_control
      cleanup_duplicate_review_test_data!(@user, @admin)
      Current.reset
      clear_enqueued_jobs
    end

    test 'proof escalation waits for the outer commit and uses the canonical request owner' do
      @flag.update!(enabled: true)
      Application.transaction do
        escalate_by_approving_proof
        assert @application.reload.status_awaiting_dcf?
        assert @application.medical_certification_status_not_requested?
        assert_empty certification_jobs
      end
      assert @application.reload.status_awaiting_dcf?
      assert @application.medical_certification_status_requested?
      assert_equal 1, @application.medical_certification_request_count
      assert @application.medical_certification_requested_at
      notification = Notification.where(notifiable: @application, action: 'medical_certification_requested').sole
      assert_equal notification.id, certification_jobs.sole.dig('email_delivery_context', 'notification_id')
      assert Event.exists?(auditable: @application, action: 'medical_certification_requested')
      @application.escalate_to_dcf!(actor: @admin)
      assert_equal 1, certification_jobs.size
    end

    test 'disabled or absent workflow flag leaves requests to staff' do
      @flag.update!(enabled: false)
      assert_not FeatureFlag.enabled?(:dcf_auto_request_certification, default: false)
      @application.escalate_to_dcf!(actor: @admin)
      assert @application.reload.medical_certification_status_not_requested?
      assert_empty certification_jobs
      @flag.destroy!
      @application.update_columns(status: Application.statuses[:in_progress])
      @application.escalate_to_dcf!(actor: @admin)
      assert_empty certification_jobs
      assert_not @application.dcf_auto_request_not_sent?
    ensure
      @flag = FeatureFlag.find_or_create_by!(name: 'dcf_auto_request_certification') { |flag| flag.enabled = false }
    end

    test 'missing provider email records a visible refusal without undoing escalation' do
      @flag.update!(enabled: true)
      @application.update_columns(medical_provider_email: nil)
      @application.escalate_to_dcf!(actor: @admin)
      assert @application.reload.status_awaiting_dcf?
      assert @application.dcf_auto_request_not_sent?
      assert Event.exists?(auditable: @application, action: 'dcf_auto_request_not_sent')
      assert_empty certification_jobs
    end

    test 'Certification off preserves escalation and requires a manual request' do
      @flag.update!(enabled: true)
      EmailDelivery::ControlWriter.set(name: @control.name, enabled: false, actor: @admin, operation_id: SecureRandom.uuid)
      @application.escalate_to_dcf!(actor: @admin)
      assert @application.reload.status_awaiting_dcf?
      assert @application.dcf_auto_request_not_sent?
      assert_equal 0, @application.medical_certification_request_count
      assert_empty certification_jobs
    end

    test 'a worker refusal restores the request and leaves the auto-send notice visible' do
      @flag.update!(enabled: true)
      @application.escalate_to_dcf!(actor: @admin)
      EmailDelivery::ControlWriter.set(name: @control.name, enabled: false, actor: @admin, operation_id: SecureRandom.uuid)
      perform_enqueued_jobs(only: MedicalCertificationEmailJob)
      assert @application.reload.status_awaiting_dcf?
      assert @application.dcf_auto_request_not_sent?
      assert_equal 0, @application.medical_certification_request_count
    end

    test 'rollback never issues an automatic request and enabling never sends for existing waiting applications' do
      @flag.update!(enabled: true)
      Application.transaction do
        @application.escalate_to_dcf!(actor: @admin)
        raise ActiveRecord::Rollback
      end
      assert @application.reload.status_in_progress?
      assert_empty certification_jobs
      @flag.update!(enabled: false)
      @application.escalate_to_dcf!(actor: @admin)
      @flag.update!(enabled: true)
      @application.escalate_to_dcf!(actor: @admin)
      assert @application.reload.medical_certification_status_not_requested?
      assert_empty certification_jobs
    end

    private

    def certification_jobs
      enqueued_jobs.select { |job| job[:job] == MedicalCertificationEmailJob }
    end

    def escalate_by_approving_proof
      @application.update_columns(residency_proof_status: Application.residency_proof_statuses[:not_reviewed])
      @application.residency_proof.attach(io: StringIO.new('proof'), filename: 'proof.pdf', content_type: 'application/pdf')
      ProofReviewer.new(@application, @admin).review(proof_type: :residency, status: :approved)
    end
  end
end
