# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class InvoicesTest < ApplicationSystemTestCase
    setup do
      ensure_system_audit_actor!
      @vendor_user = create(:vendor_user)
      system_test_sign_in(@vendor_user)
    end

    test 'the dashboard shows what is not yet invoiced apart from what is invoiced and awaiting payment' do
      create(:voucher_transaction, vendor: @vendor_user, amount: 30)
      invoice = create(:invoice, :pending, :with_transactions, vendor: @vendor_user, transaction_count: 1, amount_per_transaction: 70)

      visit vendor_portal_dashboard_path

      assert_selector 'dl', text: /Not yet invoiced\s*\$30\.00/
      assert_selector 'dl', text: /Invoiced, awaiting payment\s*\$70\.00/
      take_screenshot('vendor-dashboard-billing-split', html: true)

      click_on 'View invoices'
      assert_selector 'h1', text: 'My Invoices'
      click_on "Invoice #{invoice.invoice_number}"
      assert_text 'Awaiting approval'
      assert_text '$70.00'
    end

    test 'a paid invoice shows its payment details' do
      invoice = create(:invoice, :pending, :with_transactions, vendor: @vendor_user, transaction_count: 1, amount_per_transaction: 99.99)
      pay_invoice!(invoice, payment_method: 'direct_deposit', payment_reference: 'DD-3141', gad_invoice_reference: 'GAD-TEST-REF')

      visit vendor_portal_invoice_path(invoice)

      assert_text invoice.invoice_number
      assert_text '$99.99'
      assert_text 'Paid'
      assert_text 'Direct deposit'
      assert_text 'DD-3141'
      assert_text 'GAD-TEST-REF'
      assert_no_text 'Recorded by'
      take_screenshot('vendor-invoice-paid', html: true)
    end
  end
end
