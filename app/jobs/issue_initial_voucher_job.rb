# frozen_string_literal: true

class IssueInitialVoucherJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(application_id, actor_id, assignment_method = 'automatic')
    application = Application.find_by(id: application_id)
    actor = User.find_by(id: actor_id)
    return unless application && actor

    application.maybe_assign_initial_voucher!(
      actor: actor,
      assignment_method: assignment_method.to_sym
    )
  rescue StandardError => e
    Rails.logger.error "IssueInitialVoucherJob failed for application #{application_id}: #{e.message}"
    raise
  end
end
