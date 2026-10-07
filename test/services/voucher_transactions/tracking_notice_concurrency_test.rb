# frozen_string_literal: true

require 'test_helper'

# Two dispatchers for the same package (its queued run and the sweep, or a retried job) must
# create one notice between them. Both sides are the real TrackingNotice.deliver! on separate connections.
module VoucherTransactions
  class TrackingNoticeConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'a dispatcher waits for one in progress and sends no second notice' do
      vendor = create(:vendor, :approved)
      voucher = create(:voucher, :active, vendor: vendor)
      purchase = create(:voucher_transaction, voucher: voucher, vendor: vendor, amount: 100)
      shipment = FulfillmentService.new(transaction: purchase, actor: vendor)
                                   .add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          TrackingNotice.deliver!(shipment.id)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        TrackingNotice.deliver!(shipment.id)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert_equal 1, Notification.where(action: TrackingNotice::ACTION, notifiable: shipment).count
      assert shipment.reload.tracking_notification_id
    ensure
      if purchase
        VoucherTransactionShipment.where(voucher_transaction_id: purchase.id).delete_all
        Notification.where(notifiable_type: 'VoucherTransactionShipment').where(notifiable_id: shipment&.id).delete_all
        Event.where(auditable: purchase).delete_all
        VoucherTransaction.where(id: purchase.id).delete_all
      end
      if voucher
        Event.where(auditable: voucher).delete_all
        Voucher.where(id: voucher.id).delete_all
      end
      cleanup_duplicate_review_test_data!(*[vendor, voucher&.application&.user].compact)
    end
  end
end
