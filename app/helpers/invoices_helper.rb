# frozen_string_literal: true

# Labels for invoice status and payment, shared by the admin and vendor invoice screens and the CSV.
module InvoicesHelper
  STATUS_LABELS = {
    'invoice_draft' => 'Draft', 'invoice_pending' => 'Awaiting approval', 'invoice_approved' => 'Approved, awaiting payment',
    'invoice_paid' => 'Paid', 'invoice_cancelled' => 'Withdrawn'
  }.freeze
  PAYMENT_METHOD_LABELS = { 'direct_deposit' => 'Direct deposit', 'eft' => 'EFT', 'check' => 'Check' }.freeze
  STATUS_COLORS = {
    'invoice_pending' => 'bg-yellow-100 text-yellow-800', 'invoice_approved' => 'bg-blue-100 text-blue-800',
    'invoice_paid' => 'bg-green-100 text-green-800', 'invoice_cancelled' => 'bg-gray-100 text-gray-800'
  }.freeze

  # Shared by the admin invoice list and invoice page.
  FORM_CLASSES = {
    input: 'mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm',
    primary: 'inline-flex items-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white ' \
             'bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500',
    secondary: 'inline-flex items-center px-4 py-2 border border-gray-300 rounded-md shadow-sm text-sm font-medium text-gray-700 ' \
               'bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500',
    small: 'inline-flex items-center px-3 py-1.5 border border-gray-300 rounded-md text-xs font-medium ' \
           'text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-indigo-500'
  }.freeze
  EVENT_DETAIL_KEYS = %w[reason reference note from_status to_status].freeze

  def invoice_form_class(kind)
    FORM_CLASSES.fetch(kind)
  end

  def invoice_not_recorded
    tag.span('Not recorded', class: 'text-gray-500')
  end

  # The check number for a check, otherwise the deposit or EFT reference. Older rows may hold only a check number.
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
    tag.span(invoice_status_label(invoice),
             class: "inline-flex rounded-full px-2 py-0.5 text-xs font-medium #{STATUS_COLORS.fetch(invoice.status, 'bg-gray-100 text-gray-800')}")
  end

  # A paid invoice from before payment methods were recorded says so rather than guessing.
  def invoice_payment_method_label(invoice)
    return if invoice.payment_method.blank? && !invoice.status_invoice_paid?

    PAYMENT_METHOD_LABELS.fetch(invoice.payment_method.to_s, 'Not recorded')
  end

  def invoice_payment_method_options
    PAYMENT_METHOD_LABELS.map { |value, label| [label, value] }
  end
end
