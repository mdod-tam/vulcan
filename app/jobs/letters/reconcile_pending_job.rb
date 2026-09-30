# frozen_string_literal: true

module Letters
  class ReconcilePendingJob < ApplicationJob
    queue_as :default
    self.enqueue_after_transaction_commit = true
    BATCH_SIZE = 100

    def perform(after_id: 0, recipient_id: nil, application_id: nil)
      scope = self.class.pending_scope(recipient_id: recipient_id, application_id: application_id)
      ids = scope.where('id > ?', after_id).order(:id).limit(BATCH_SIZE).pluck(:id)
      Delivery.reconcile_pending!(scope: PrintQueueItem.where(id: ids))
      return unless ids.size == BATCH_SIZE

      self.class.schedule(after_id: ids.last, recipient_id: recipient_id, application_id: application_id)
    end

    def self.pending_scope(recipient_id: nil, application_id: nil)
      scope = PrintQueueItem.unreleased
      scope = scope.where(constituent_id: recipient_id) if recipient_id
      scope = scope.where(application_id: application_id) if application_id
      scope
    end

    # Register at the identity write, not after_update_commit: a later save in the
    # same transaction can replace saved_changes. Rollback discards this callback.
    def self.schedule(**scope)
      ActiveRecord.after_all_transactions_commit do
        next if scope.any? && !pending_scope(**scope.except(:after_id)).exists?

        job = perform_later(**scope)
        unless job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
          error_class = job.enqueue_error&.class&.name if job.respond_to?(:enqueue_error)
          record_enqueue_failure(scope, error_class)
        end
      rescue StandardError => e
        record_enqueue_failure(scope, e.class.name)
      end
    end

    def self.record_enqueue_failure(scope, error_class)
      Rails.logger.error('Letter cancellation reconciliation was not queued; release remains policy-gated')
      actor = PublicAuditActor.system_audit_actor_or_report('letter_reconciliation_enqueue_failed')
      return unless actor

      AuditEventService.log(action: 'letter_reconciliation_enqueue_failed', actor: actor,
                            metadata: scope.merge(error_class: error_class))
    rescue StandardError => e
      Rails.logger.error("Letter reconciliation failure audit could not be recorded: #{e.class}")
    end
    private_class_method :record_enqueue_failure
  end
end
