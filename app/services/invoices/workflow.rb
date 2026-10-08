# frozen_string_literal: true

module Invoices
  # The one writer for an invoice after it is generated: approval, payment, withdrawal, and
  # correction notes. Every operation locks the invoice row and decides from what is stored there.
  #
  # expected_status is what the staff member's form showed. A different stored status means the form
  # was stale or was submitted twice; the operation then changes nothing and says what happened.
  # Each change and its audit event commit together; the vendor's payment notice is queued after commit,
  # so a notice that cannot be queued never undoes a recorded payment.
  class Workflow
    # Shown to staff as is.
    class Refused < StandardError; end

    PAYMENT_FIELDS = %i[payment_date payment_method payment_reference check_number gad_invoice_reference payment_notes].freeze

    def initialize(invoice, actor:)
      @invoice = invoice
      @actor = actor
    end

    def approve!(expected_status:)
      change(expected_status, action: 'invoice_approved') do |invoice|
        invoice.update!(status: :invoice_approved, approved_at: Time.current)
      end
    end

    # One full payment per invoice. Raises ActiveRecord::RecordInvalid when details are missing.
    def record_payment!(expected_status:, **details)
      payment_date = DateInputNormalizer.normalize(details[:payment_date])
      invoice = change(expected_status, action: 'invoice_payment_recorded') do |locked|
        locked.update!(details.slice(*PAYMENT_FIELDS).merge(payment_date: payment_date, status: :invoice_paid,
                                                            paid_by: @actor, payment_recorded_at: Time.current))
      end
      notify_vendor_of_payment(invoice)
      invoice
    end

    # Releases the invoice's purchases so a later invoice can include them. The invoice and its number stay.
    def withdraw!(expected_status:, reason:)
      raise Refused, 'Give a reason for withdrawing this invoice.' if reason.to_s.strip.blank?

      change(expected_status, action: 'invoice_withdrawn', reason: reason.to_s.strip) do |invoice|
        invoice.update!(status: :invoice_cancelled)
        released = invoice.voucher_transactions.to_a
        released.each { |purchase| purchase.update!(invoice: nil) }
        { released_transaction_ids: released.map(&:id) }
      end
    end

    # A correction never edits the original record; it is an audited note with its accounting reference.
    def add_correction_note!(reference:, note:)
      raise Refused, 'Enter the accounting reference and a note for the correction.' if reference.to_s.strip.blank? || note.to_s.strip.blank?

      AuditEventService.log(
        action: 'invoice_correction_noted', actor: @actor, auditable: @invoice,
        metadata: { reference: reference.to_s.strip, note: note.to_s.strip, operation_id: SecureRandom.uuid }
      )
      @invoice
    end

    private

    def change(expected_status, action:, **metadata)
      Invoice.transaction do
        invoice = Invoice.lock.find(@invoice.id)
        unless invoice.status == expected_status.to_s
          raise Refused, "This invoice changed since the page was opened: it is now #{status_name(invoice)}. Nothing was changed."
        end

        extra = yield(invoice)
        AuditEventService.log(
          action: action, actor: @actor, auditable: invoice,
          metadata: metadata.merge(extra.is_a?(Hash) ? extra : {})
                            .merge(from_status: expected_status.to_s, to_status: invoice.status, operation_id: SecureRandom.uuid)
        )
        @invoice = invoice
      end
    end

    def status_name(invoice)
      invoice.status_invoice_cancelled? ? 'withdrawn' : invoice.status.delete_prefix('invoice_').humanize.downcase
    end

    def notify_vendor_of_payment(invoice)
      outcome = EmailDelivery.deliver_later(VendorNotificationsMailer.with(invoice: invoice).payment_issued)
      record_notice_failure(invoice, 'ActiveJob::EnqueueError') if outcome == :enqueue_failed
    rescue StandardError => e
      record_notice_failure(invoice, e.class.name)
    end

    def record_notice_failure(invoice, error_class)
      Rails.logger.error("Payment notice for invoice #{invoice.id} could not be queued: #{error_class}")
      invoice.events.create!(user: @actor, action: 'invoice_notification_enqueue_failed', metadata: { error_class: error_class })
    rescue StandardError => e
      Rails.logger.error("Recording the payment notice failure for invoice #{invoice.id} failed: #{e.class}")
    end
  end
end
