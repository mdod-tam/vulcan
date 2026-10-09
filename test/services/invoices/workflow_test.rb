# frozen_string_literal: true

require 'test_helper'

module Invoices
  class WorkflowTest < ActiveJob::TestCase
    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      @vendor = create(:vendor, :approved)
      @invoice = create(:invoice, :pending, :with_transactions, vendor: @vendor, transaction_count: 2)
    end

    test 'approval and payment record who, when, how, and the references, each with an audit event' do
      workflow.approve!(expected_status: 'invoice_pending')
      paid = workflow.record_payment!(expected_status: 'invoice_approved', payment_date: '10/06/2026',
                                      payment_method: 'check', check_number: 'CHK-1001',
                                      gad_invoice_reference: 'GAD-77', payment_notes: 'Mailed')

      assert paid.status_invoice_paid?
      assert_equal Date.new(2026, 10, 6), paid.payment_date.to_date
      assert paid.paid_by_check?
      assert_equal ['CHK-1001', 'GAD-77', @admin], [paid.check_number, paid.gad_invoice_reference, paid.paid_by]
      assert paid.approved_at && paid.payment_recorded_at
      assert_equal %w[invoice_approved invoice_payment_recorded], Event.where(auditable: paid).order(:id).pluck(:action) & %w[invoice_approved invoice_payment_recorded]
    end

    test 'a stale approval form cannot move a paid invoice back, and a repeated payment changes nothing' do
      pay_invoice!(@invoice, actor: @admin, payment_reference: 'EFT-1')

      error = assert_raises(Workflow::Refused) { workflow.approve!(expected_status: 'invoice_pending') }
      assert_match(/it is now paid. Nothing was changed/, error.message)
      assert_raises(Workflow::Refused) do
        workflow.record_payment!(expected_status: 'invoice_approved', payment_date: Date.current, payment_method: 'eft',
                                 payment_reference: 'EFT-2', gad_invoice_reference: 'GAD-2')
      end

      assert_equal 'EFT-1', @invoice.reload.payment_reference
      assert @invoice.status_invoice_paid?
      assert_equal 1, Event.where(auditable: @invoice, action: 'invoice_payment_recorded').count
    end

    test 'incomplete payment details are refused and nothing is recorded' do
      approve_invoice!(@invoice, actor: @admin)

      assert_raises(ActiveRecord::RecordInvalid) do
        workflow.record_payment!(expected_status: 'invoice_approved', payment_date: '', payment_method: 'check',
                                 gad_invoice_reference: '')
      end
      assert @invoice.reload.status_invoice_approved?
      assert_nil @invoice.payment_recorded_at
    end

    test 'a payment whose audit event fails is rolled back' do
      approve_invoice!(@invoice, actor: @admin)
      AuditEventService.stubs(:log).raises(ActiveRecord::StatementInvalid)

      assert_raises(ActiveRecord::StatementInvalid) do
        workflow.record_payment!(expected_status: 'invoice_approved', payment_date: Date.current, payment_method: 'eft',
                                 payment_reference: 'EFT-9', gad_invoice_reference: 'GAD-9')
      end
      assert @invoice.reload.status_invoice_approved?
      assert_nil @invoice.payment_reference
    end

    test 'a payment notice that cannot be queued leaves the payment recorded' do
      approve_invoice!(@invoice, actor: @admin)
      EmailDelivery.stubs(:deliver_later).raises(ActiveJob::EnqueueError)

      paid = workflow.record_payment!(expected_status: 'invoice_approved', payment_date: Date.current, payment_method: 'eft',
                                      payment_reference: 'EFT-9', gad_invoice_reference: 'GAD-9')

      assert paid.reload.status_invoice_paid?
      assert Event.exists?(auditable: paid, action: 'invoice_notification_enqueue_failed')
    end

    test 'payment queues exactly one vendor notice, after commit' do
      approve_invoice!(@invoice, actor: @admin)

      assert_enqueued_jobs 1, only: EmailDelivery::MailDeliveryJob do
        workflow.record_payment!(expected_status: 'invoice_approved', payment_date: Date.current, payment_method: 'direct_deposit',
                                 payment_reference: 'DD-1', gad_invoice_reference: 'GAD-1')
      end
    end

    test 'withdrawing releases the purchases for a later invoice and keeps the invoice' do
      approve_invoice!(@invoice, actor: @admin)
      purchase_ids = @invoice.voucher_transaction_ids

      workflow.withdraw!(expected_status: 'invoice_approved', reason: 'Wrong vendor billed')

      assert @invoice.reload.status_invoice_cancelled?
      assert_empty @invoice.voucher_transactions
      assert_equal purchase_ids.sort, VoucherTransaction.billable.where(id: purchase_ids).pluck(:id).sort
      assert_equal 'Wrong vendor billed', Event.find_by!(auditable: @invoice, action: 'invoice_withdrawn').metadata['reason']

      Invoices::GenerationService.new(now: 1.day.from_now).call
      reissued = Invoice.for_vendor(@vendor.id).where.not(id: @invoice.id).sole
      assert_equal purchase_ids.sort, reissued.voucher_transaction_ids.sort
    end

    test 'a paid invoice cannot be withdrawn and a withdrawal needs a reason' do
      assert_raises(Workflow::Refused) { workflow.withdraw!(expected_status: 'invoice_pending', reason: ' ') }
      pay_invoice!(@invoice, actor: @admin)

      assert_raises(Workflow::Refused) { workflow.withdraw!(expected_status: 'invoice_pending', reason: 'Fraud') }
      assert_raises(ActiveRecord::RecordInvalid) { workflow.withdraw!(expected_status: 'invoice_paid', reason: 'Fraud') }
      assert @invoice.reload.status_invoice_paid?
      assert_equal 2, @invoice.voucher_transactions.count
    end

    test 'a held purchase stays off invoices until released' do
      suspect, legitimate = @invoice.voucher_transactions.order(:id).to_a
      workflow.withdraw!(expected_status: 'invoice_pending', reason: 'Suspected fraud')
      VoucherTransactions::BillingHold.new(suspect, actor: @admin).hold!(reason: 'Under review')

      Invoices::GenerationService.new(now: 1.day.from_now).call
      reissued = Invoice.for_vendor(@vendor.id).where.not(id: @invoice.id).sole
      assert_equal [legitimate.id], reissued.voucher_transaction_ids
      assert suspect.reload.on_billing_hold?
      assert_equal 'Under review', suspect.billing_hold_reason

      VoucherTransactions::BillingHold.new(suspect, actor: @admin).release!
      assert_includes VoucherTransaction.billable, suspect.reload
    end

    test 'a purchase on an invoice cannot be held' do
      purchase = @invoice.voucher_transactions.first

      error = assert_raises(VoucherTransactions::BillingHold::Refused) do
        VoucherTransactions::BillingHold.new(purchase, actor: @admin).hold!(reason: 'Check')
      end
      assert_match(/Withdraw the invoice/, error.message)
    end

    test 'a correction is an audited note and never edits the payment' do
      pay_invoice!(@invoice, actor: @admin, payment_reference: 'EFT-1')

      workflow.add_correction_note!(reference: 'JE-2026-114', note: 'Reversed duplicate deposit')

      event = Event.find_by!(auditable: @invoice, action: 'invoice_correction_noted')
      assert_equal 'JE-2026-114', event.metadata['reference']
      assert_equal 'EFT-1', @invoice.reload.payment_reference
    end

    private

    def workflow
      Workflow.new(Invoice.find(@invoice.id), actor: @admin)
    end
  end
end
