# frozen_string_literal: true

# Moves an invoice through approval and payment the way staff do, through Invoices::Workflow.
module InvoiceWorkflowTestHelper
  def approve_invoice!(invoice, actor: create(:admin))
    Invoices::Workflow.new(invoice, actor: actor).approve!(expected_status: invoice.reload.status)
  end

  def pay_invoice!(invoice, actor: create(:admin), **details)
    approve_invoice!(invoice, actor: actor) unless invoice.reload.status_invoice_approved?
    Invoices::Workflow.new(invoice, actor: actor).record_payment!(
      expected_status: 'invoice_approved',
      payment_date: details.fetch(:payment_date, Date.current),
      payment_method: details.fetch(:payment_method, 'eft'),
      payment_reference: details.fetch(:payment_reference, "EFT-#{SecureRandom.hex(3).upcase}"),
      check_number: details[:check_number],
      gad_invoice_reference: details.fetch(:gad_invoice_reference, "GAD-#{SecureRandom.hex(4).upcase}"),
      payment_notes: details[:payment_notes]
    )
  end
end

ActiveSupport.on_load(:active_support_test_case) { include InvoiceWorkflowTestHelper }
