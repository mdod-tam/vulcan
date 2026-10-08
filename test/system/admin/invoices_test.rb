# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class InvoicesTest < ApplicationSystemTestCase
    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      @vendor = create(:vendor, :approved, business_name: 'Ray Supply')
      @invoice = create(:invoice, :pending, :with_transactions, vendor: @vendor,
                                                                transaction_count: 2, amount_per_transaction: 50)
      sign_in(@admin)
    end

    test 'staff approve an invoice and record a check payment' do
      visit admin_invoice_path(@invoice)
      click_on 'Approve invoice'
      assert_text 'Invoice approved.'

      fill_in 'Payment date', with: Date.current.strftime('%m/%d/%Y')
      select 'Check', from: 'Payment method'
      fill_in 'GAD invoice reference', with: 'GAD-2210'
      click_on 'Record payment'

      assert_text 'The payment was not recorded'
      assert_text "Check number can't be blank"
      take_screenshot('admin-invoice-payment-errors', html: true)
      assert_field 'GAD invoice reference', with: 'GAD-2210'

      fill_in 'Check number (checks)', with: 'CHK-4410'
      click_on 'Record payment'

      assert_text 'Payment recorded.'
      assert_text 'CHK-4410'
      assert_text 'GAD-2210'
      assert_no_button 'Record payment'
      take_screenshot('admin-invoice-paid', html: true)
      assert @invoice.reload.status_invoice_paid?
    end

    test 'staff withdraw an invoice and its purchases return to not yet invoiced' do
      visit admin_invoice_path(@invoice)
      fill_in 'Reason', with: 'Billed to the wrong vendor'
      accept_confirm { click_on 'Withdraw invoice' }

      assert_text 'Invoice withdrawn. Its purchases are released and can be added to a later invoice.'
      assert_text 'Withdrawn'

      visit admin_invoices_path
      within('section', text: 'Not yet invoiced') do
        assert_text 'Ray Supply'
        assert_text '$100.00 in 2 purchases'
        assert_button 'Invoice now'
      end
      take_screenshot('admin-invoices-not-yet-invoiced', html: true)
    end
  end
end
