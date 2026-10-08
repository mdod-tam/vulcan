# frozen_string_literal: true

require 'zlib'

module Invoices
  # Called by GenerateVendorInvoicesJob every 14 days, and by staff ("Invoice now" / retry) for one vendor.
  #
  # Each run uses one cutoff: the start of the run day, Eastern. Every completed, uninvoiced purchase
  # processed before it and not on a staff billing hold is invoiced, however old, so a missed or failed
  # run loses nothing. A purchase at exactly midnight belongs to the next run.
  #
  # For each vendor, one transaction creates the invoice and claims the purchases with a conditional
  # update (invoice_id IS NULL), so a purchase can be on only one invoice. The invoice period and total
  # come from what was claimed; if nothing was claimed, no invoice is left behind.
  #
  # Runs never overlap: scheduled runs and staff retries share one session-level advisory lock. A run
  # that finds the lock taken reports that invoicing is already running; it is not a failure.
  # A vendor whose invoicing fails is recorded in InvoiceGenerationFailure for staff to retry; a later
  # success resolves it. Invoice email is queued after commit and never undoes a committed invoice.
  class GenerationService < BaseService
    LOCK_KEY = Zlib.crc32('invoices.generation')
    ZONE = 'Eastern Time (US & Canada)'
    NUMBER_ATTEMPTS = 3

    def self.cutoff(now = Time.current)
      now.in_time_zone(ZONE).beginning_of_day
    end

    # vendor_ids limits the run to those vendors (staff retry); nil means every vendor with eligible purchases.
    def initialize(vendor_ids: nil, now: Time.current)
      super()
      @vendor_ids = vendor_ids
      @cutoff = self.class.cutoff(now)
    end

    def call
      with_run_lock do
        invoices = vendors_to_invoice.filter_map { |vendor_id| invoice_vendor(vendor_id) }
        failed = InvoiceGenerationFailure.unresolved.where(vendor_id: vendors_attempted).count
        success("Generated #{invoices.size} invoices", { invoices_created: invoices.size, invoices: invoices, vendors_failed: failed })
      end
    rescue StandardError => e
      log_error(e, 'Failed to generate vendor invoices')
      failure('Failed to generate vendor invoices')
    end

    private

    attr_reader :cutoff

    def with_run_lock
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        locked = connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})")
        return success('Invoicing is already running', { already_running: true, invoices_created: 0 }) unless locked

        begin
          yield
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{LOCK_KEY})")
        end
      end
    end

    def eligible_purchases
      VoucherTransaction.billable.where(processed_at: ...cutoff)
    end

    def vendors_to_invoice
      scope = eligible_purchases
      scope = scope.where(vendor_id: @vendor_ids) if @vendor_ids
      @vendors_attempted = scope.distinct.pluck(:vendor_id)
    end

    def vendors_attempted
      @vendors_attempted || []
    end

    # Returns the committed invoice, or nil when nothing was claimed or the vendor failed.
    def invoice_vendor(vendor_id)
      invoice = create_invoice_with_unique_number(vendor_id)
      InvoiceGenerationFailure.resolve!(vendor_id)
      return unless invoice

      queue_vendor_notification(invoice)
      invoice
    rescue StandardError => e
      log_error(e, "Failed to generate invoice for vendor #{vendor_id}")
      InvoiceGenerationFailure.record!(vendor_id: vendor_id, cutoff: cutoff, error: e)
      nil
    end

    # A number collision rolls the whole vendor transaction back; only then is a new number tried.
    # The uniqueness validation usually reports it; the unique index catches a concurrent insert.
    def create_invoice_with_unique_number(vendor_id)
      attempts = 0
      begin
        attempts += 1
        create_invoice(vendor_id)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        raise unless invoice_number_collision?(e) && attempts < NUMBER_ATTEMPTS

        retry
      end
    end

    def invoice_number_collision?(error)
      if error.is_a?(ActiveRecord::RecordInvalid)
        error.record.is_a?(Invoice) && error.record.errors.of_kind?(:invoice_number, :taken)
      else
        error.message.include?('index_invoices_on_invoice_number')
      end
    end

    def create_invoice(vendor_id)
      ActiveRecord::Base.transaction do
        invoice = Invoice.create!(vendor_id: vendor_id, start_date: cutoff - 1.day, end_date: cutoff,
                                  status: :invoice_pending, invoice_number: Invoice.generate_number)
        claimed = eligible_purchases.where(vendor_id: vendor_id)
                                    .update_all(invoice_id: invoice.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        raise ActiveRecord::Rollback if claimed.zero?

        purchases = invoice.voucher_transactions
        invoice.update!(start_date: purchases.minimum(:processed_at).in_time_zone(ZONE).beginning_of_day,
                        total_amount: purchases.sum(:amount))
        create_invoice_event(invoice, claimed)
        invoice
      end
    end

    # With no system audit account, the invoice still saves and PublicAuditActor reports the gap.
    def create_invoice_event(invoice, claimed)
      return unless (actor = PublicAuditActor.system_audit_actor_or_report('invoice generated event'))

      invoice.events.create!(
        user: actor,
        action: 'generated',
        metadata: {
          transaction_count: claimed,
          total_amount: invoice.total_amount,
          period: { start: invoice.start_date, end: invoice.end_date },
          cutoff: cutoff
        }
      )
    end

    # Policy refusals return :suppressed or :configuration_error. Only queue failures get an enqueue-failure event.
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
