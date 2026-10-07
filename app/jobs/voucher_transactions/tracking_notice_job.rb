# frozen_string_literal: true

module VoucherTransactions
  # With a shipment id, sends that package's first-tracking notice; without one (the recurring
  # schedule), sends every notice still owed. Safe to run more than once; see TrackingNotice.
  class TrackingNoticeJob < ApplicationJob
    queue_as :default
    self.enqueue_after_transaction_commit = true

    def perform(shipment_id = nil)
      shipment_id ? TrackingNotice.deliver!(shipment_id) : TrackingNotice.sweep!
    end
  end
end
