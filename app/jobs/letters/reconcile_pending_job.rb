# frozen_string_literal: true

module Letters
  class ReconcilePendingJob < ApplicationJob
    queue_as :default
    self.enqueue_after_transaction_commit = true
    BATCH_SIZE = 100

    def perform(after_id: 0)
      items = PrintQueueItem.unreleased.where('id > ?', after_id).order(:id).limit(BATCH_SIZE).to_a
      items.each do |item|
        decision = item.delivery_decision
        Delivery.cancel!(item, reason: decision.reason) if decision.suppressed?
      end
      self.class.perform_later(after_id: items.last.id) if items.size == BATCH_SIZE
    end

    def self.schedule
      ActiveRecord.after_all_transactions_commit do
        job = perform_later
        unless job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
          Rails.logger.error('Letter cancellation reconciliation was not queued; release remains policy-gated')
        end
      rescue StandardError => e
        Rails.logger.error("Letter cancellation reconciliation was not queued: #{e.class}; release remains policy-gated")
      end
    end
  end
end
