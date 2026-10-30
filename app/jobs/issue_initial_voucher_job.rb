# frozen_string_literal: true

class IssueInitialVoucherJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  # Queues the initial voucher for a newly approved application. Equipment fulfillment issues no voucher.
  def self.enqueue_after_approval(application, actor:, assignment_method:)
    return unless application.voucher_fulfillment?

    perform_later(application.id, actor.id, assignment_method.to_s)
  end

  def perform(application_id, actor_id, assignment_method = 'automatic')
    application = Application.find_by(id: application_id)
    actor = User.find_by(id: actor_id)
    return unless application && actor

    Vouchers::IssuanceService.new(
      application,
      actor: actor,
      assignment_method: assignment_method.to_sym,
      raise_on_failure: true
    ).call
  rescue StandardError => e
    Rails.logger.error "IssueInitialVoucherJob failed for application #{application_id}: #{e.class.name}"
    raise
  end
end
