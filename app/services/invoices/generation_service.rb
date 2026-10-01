# frozen_string_literal: true

module Invoices
  # Service to generate invoices for vendors with uninvoiced transactions
  #
  # LOGIC FLOW:
  # 1. Find all vendors with uninvoiced transactions (VoucherTransaction.completed.where(invoice_id: nil))
  # 2. For each vendor:
  #    a. Calculate date range (from last invoice end_date or 14 days ago)
  #    b. Find uninvoiced transactions in that date range
  #    c. Create Invoice record with calculated totals
  #    d. Associate transactions with the new invoice
  #    e. Create audit event for the invoice
  #    f. After commit, queue the vendor notice
  #
  # MODELS USED:
  # - VoucherTransaction (finding uninvoiced transactions)
  # - Invoice (creating new invoices, finding latest for date range)
  #
  # MAILERS USED:
  # - VendorNotificationsMailer.invoice_generated (notifies vendor)
  #
  # CALLED BY:
  # - GenerateVendorInvoicesJob (app/jobs/generate_vendor_invoices_job.rb)
  #
  class GenerationService < BaseService
    def call
      vendor_ids = find_vendors_with_uninvoiced_transactions

      return success('No vendors found with uninvoiced transactions', { invoices_created: 0 }) if vendor_ids.empty?

      invoices_created = 0

      vendor_ids.each do |vendor_id|
        result = generate_invoice_for_vendor(vendor_id)
        invoices_created += 1 if result.success? && result.data&.dig(:invoice)
      end

      success("Generated #{invoices_created} invoices", { invoices_created: invoices_created })
    rescue StandardError => e
      log_error(e, 'Failed to generate vendor invoices')
      failure('Failed to generate vendor invoices')
    end

    private

    def find_vendors_with_uninvoiced_transactions
      VoucherTransaction
        .completed
        .where(invoice_id: nil)
        .select(:vendor_id)
        .distinct
        .pluck(:vendor_id)
    end

    def generate_invoice_for_vendor(vendor_id)
      date_range = calculate_date_range_for_vendor(vendor_id)
      transactions = find_uninvoiced_transactions(vendor_id, date_range)

      return success('No transactions found for vendor') if transactions.empty?

      invoice = ActiveRecord::Base.transaction do
        created = create_invoice(vendor_id, date_range)
        associate_transactions_with_invoice(transactions, created)
        created.update!(total_amount: created.voucher_transactions.sum(:amount))
        create_invoice_event(created, date_range)
        created
      end

      # The invoice is committed; a notice that cannot be queued does not undo it.
      notification = queue_vendor_notification(invoice)
      success('Invoice generated successfully', { invoice: invoice, notification: notification })
    rescue StandardError => e
      log_error(e, "Failed to generate invoice for vendor #{vendor_id}")
      failure("Failed to generate invoice for vendor #{vendor_id}")
    end

    def calculate_date_range_for_vendor(vendor_id)
      latest_invoice = Invoice.for_vendor(vendor_id).order(end_date: :desc).first
      start_date = latest_invoice ? latest_invoice.end_date : 14.days.ago.beginning_of_day
      end_date = Time.current.end_of_day

      { start_date: start_date, end_date: end_date }
    end

    def find_uninvoiced_transactions(vendor_id, date_range)
      VoucherTransaction
        .completed
        .where(invoice_id: nil)
        .where(vendor_id: vendor_id)
        .where(processed_at: date_range[:start_date]..date_range[:end_date])
    end

    def create_invoice(vendor_id, date_range)
      Invoice.create!(
        vendor_id: vendor_id,
        start_date: date_range[:start_date],
        end_date: date_range[:end_date],
        status: :invoice_pending
      )
    end

    def associate_transactions_with_invoice(transactions, invoice)
      transactions.find_each do |transaction|
        transaction.update!(invoice_id: invoice.id)
      end
    end

    # The invoice stands even when no system audit account is configured; that gap is reported.
    def create_invoice_event(invoice, date_range)
      return unless (actor = PublicAuditActor.system_audit_actor_or_report('invoice generated event'))

      invoice.events.create!(
        user: actor,
        action: 'generated',
        metadata: {
          transaction_count: invoice.voucher_transactions.count,
          total_amount: invoice.total_amount,
          period: {
            start: date_range[:start_date],
            end: date_range[:end_date]
          }
        }
      )
    end

    # Policy refusals keep their :suppressed or :configuration_error result; only queue failures get an invoice enqueue event.
    def queue_vendor_notification(invoice)
      outcome = EmailDelivery.deliver_later(VendorNotificationsMailer.with(invoice: invoice).invoice_generated)
      record_notification_enqueue_failure(invoice, 'ActiveJob::EnqueueError') if outcome == :enqueue_failed
      outcome
    rescue StandardError => e
      log_error(e, "Failed to queue invoice notice for invoice #{invoice.id}")
      record_notification_enqueue_failure(invoice, e.class.name)
      :enqueue_failed
    end

    def record_notification_enqueue_failure(invoice, error_class)
      return unless (actor = PublicAuditActor.system_audit_actor_or_report('invoice notice enqueue failure'))

      invoice.events.create!(
        user: actor,
        action: 'invoice_notification_enqueue_failed',
        metadata: { error_class: error_class }
      )
    rescue StandardError => e
      log_error(e, "Failed to record invoice notice failure for invoice #{invoice.id}")
    end
  end
end
