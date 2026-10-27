# frozen_string_literal: true

# Labels for invoice status and payment, shared by the admin and vendor invoice screens and the CSV.
module InvoicesHelper
  STATUS_LABELS = {
    'invoice_draft' => 'Draft', 'invoice_pending' => 'Awaiting approval', 'invoice_approved' => 'Approved, awaiting payment',
    'invoice_paid' => 'Paid', 'invoice_cancelled' => 'Withdrawn'
  }.freeze
  PAYMENT_METHOD_LABELS = { 'direct_deposit' => 'Direct deposit', 'eft' => 'EFT', 'check' => 'Check' }.freeze

  # Shared by the admin invoice list and invoice page.
  FORM_CLASSES = {
    input: 'form-input mt-1',
    primary: 'btn btn-primary',
    secondary: 'btn btn-outline',
    small: 'btn btn-outline btn-sm'
  }.freeze
  EVENT_DETAIL_KEYS = %w[reason reference note from_status to_status].freeze

  def invoice_form_class(kind)
    FORM_CLASSES.fetch(kind)
  end

  def invoice_not_recorded
    tag.span('Not recorded', class: 'text-gray-500')
  end

  # The check number for a check, otherwise the deposit or EFT reference. Falls back to the check number when
  # no reference was recorded.
  def invoice_settlement_reference(invoice)
    reference = invoice.paid_by_check? ? invoice.check_number : invoice.payment_reference
    reference.presence || invoice.check_number.presence
  end

  # Reasons, references, notes, and status changes from an invoice history event, with statuses relabeled.
  def invoice_event_details(event)
    details = event.metadata.to_h.slice(*EVENT_DETAIL_KEYS).compact_blank
    return if details.empty?

    tag.p(details.map { |key, value| "#{key.humanize}: #{key.end_with?('_status') ? STATUS_LABELS.fetch(value, value) : value}" }.join(' · '),
          class: 'text-gray-700 mt-1')
  end

  def invoice_status_label(invoice)
    STATUS_LABELS.fetch(invoice.status, invoice.status.humanize)
  end

  def invoice_status_badge(invoice)
    status_badge(:invoice, invoice.status, label: invoice_status_label(invoice), size: nil)
  end

  # A paid invoice with no recorded payment method says so rather than guessing.
  def invoice_payment_method_label(invoice)
    return if invoice.payment_method.blank? && !invoice.status_invoice_paid?

    PAYMENT_METHOD_LABELS.fetch(invoice.payment_method.to_s, 'Not recorded')
  end

  def invoice_payment_method_options
    PAYMENT_METHOD_LABELS.map { |value, label| [label, value] }
  end
end
