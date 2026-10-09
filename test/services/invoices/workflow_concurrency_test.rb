# frozen_string_literal: true

require 'test_helper'

# Two staff members recording the same payment at once: the second waits for the first, then finds the
# invoice already paid and records nothing. Both sides are the real Invoices::Workflow on separate connections.
module Invoices
  class WorkflowConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'a concurrent second payment submission is refused and the first payment stands' do
      admin = create(:admin)
      other_admin = create(:admin)
      vendor = create(:vendor, :approved)
      invoice = create(:invoice, :approved, vendor: vendor)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          record_payment(invoice, admin, 'EFT-FIRST')
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      contender_error = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        record_payment(invoice, other_admin, 'EFT-SECOND')
      rescue Workflow::Refused => e
        contender_error = e
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert_match(/it is now paid/, contender_error&.message)
      invoice.reload
      assert_equal ['EFT-FIRST', admin.id], [invoice.payment_reference, invoice.paid_by_id]
      assert_equal 1, Event.where(auditable: invoice, action: 'invoice_payment_recorded').count
    ensure
      if invoice
        Event.where(auditable: invoice).delete_all
        EmailDeliveryAttempt.where(origin: invoice).delete_all if defined?(EmailDeliveryAttempt)
        Invoice.where(id: invoice.id).delete_all
      end
      cleanup_duplicate_review_test_data!(*[admin, other_admin, vendor].compact)
    end

    private

    def record_payment(invoice, actor, reference)
      Workflow.new(Invoice.find(invoice.id), actor: User.find(actor.id)).record_payment!(
        expected_status: 'invoice_approved', payment_date: Date.current, payment_method: 'eft',
        payment_reference: reference, gad_invoice_reference: "GAD-#{reference}"
      )
    end
  end
end
