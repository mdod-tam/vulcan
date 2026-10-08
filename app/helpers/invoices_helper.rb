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
