# frozen_string_literal: true

class IssueInitialVoucherJob < ApplicationJob
  class AttentionRecordingFailed < StandardError; end

  self.enqueue_after_transaction_commit = true

  queue_as :default
  retry_on Vouchers::IssuanceService::RolledBackFailure, wait: :polynomially_longer, attempts: 5

  # Queues the initial voucher for a newly approved application. Equipment fulfillment issues no voucher.
  def self.enqueue_after_approval(application, actor:, assignment_method:)
    return unless application.voucher_fulfillment?

    perform_later(application.id, actor.id, assignment_method.to_s)
  end

  def perform(application_id, actor_id, assignment_method = 'automatic')
    application = Application.find_by(id: application_id)
    actor = User.find_by(id: actor_id)
    return unless application && actor

    result = Vouchers::IssuanceService.new(
      application,
      actor: actor,
      assignment_method: assignment_method.to_sym,
      raise_on_failure: true
    ).call

    record_attention(application, actor, assignment_method, result) if result.data&.dig(:warning) || result.data&.dig(:commit_state) == :unknown
  rescue StandardError => e
    Rails.logger.error "IssueInitialVoucherJob failed for application #{application_id}: #{e.class.name}"
    raise
  end

  private

  def record_attention(application, actor, assignment_method, result)
    metadata = {
      application_id: application.id,
      voucher_id: result.data[:voucher]&.id,
      commit_state: result.data[:warning] ? 'committed' : 'unknown',
      assignment_method: assignment_method.to_s,
      job_id: job_id,
      operation_id: job_id
    }.compact
    recipient = actor.admin? ? actor : PublicAuditActor.system_audit_actor
    raise PublicAuditActor::MissingSystemActor unless recipient

    ApplicationRecord.transaction do
      AuditEventService.log(action: 'initial_voucher_issuance_attention', actor: actor, auditable: application, metadata: metadata)
      NotificationService.create_and_deliver!(
        type: 'initial_voucher_issuance_attention', recipient: recipient, actor: actor, notifiable: application,
        deliver: false, metadata: metadata
      )
    end
  rescue StandardError => e
    raise AttentionRecordingFailed,
          "Initial voucher issuance needs manual review: application_id=#{application.id}, " \
          "voucher_id=#{metadata[:voucher_id] || 'unconfirmed'}, job_id=#{job_id}, " \
          "commit_state=#{metadata[:commit_state]}, error_class=#{e.class.name}. " \
          'Check voucher and delivery status before retrying or issuing another voucher.', cause: nil
  end
end
