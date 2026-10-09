# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class InvoicesControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper
    include ActionView::Helpers::NumberHelper

    setup do
      ensure_system_audit_actor!
      @vendor_user = create(:vendor_user)
      sign_in_with_headers(@vendor_user)
      @invoices = create_list(:invoice, 3, vendor: @vendor_user)
    end

    test 'index lists the invoices by number and status' do
      get vendor_portal_invoices_url

      assert_response :success
      assert_select 'h1', 'My Invoices'
      assert_select 'ul[role="list"] li', count: @invoices.count
      @invoices.each { |invoice| assert_match "Invoice #{invoice.invoice_number}", response.body }
      assert_match 'Awaiting approval', response.body
    end

    test 'invoice pages retain vendor scope and use stable newest-first ordering' do
      # rubocop:disable-next FactoryBot/ExcessiveCreateList -- Exercises more than one 20-row page.
      create_list(:invoice, 20, vendor: @vendor_user)
      other_invoice = create(:invoice, vendor: create(:vendor_user))
      expected = @vendor_user.invoices.order(created_at: :desc, id: :desc).to_a

      get vendor_portal_invoices_url

      assert_response :success
      assert_select 'ul[role="list"] li', count: 20
      assert_select 'nav[aria-label="Invoice pages"] [aria-current="page"]', text: '1'
      assert_no_match other_invoice.invoice_number, response.body

      get vendor_portal_invoices_url(page: 2)

      assert_response :success
      assert_select 'ul[role="list"] li', count: 3
      expected.last(3).each { |invoice| assert_match invoice.invoice_number, response.body }
      assert_select 'nav[aria-label="Invoice pages"] [aria-current="page"]', text: '2'
    end

    test 'the vendor sees the same settlement facts staff recorded, without the internal ones' do
      admin = create(:admin, first_name: 'Rhea', last_name: 'Ledger')
      invoice = create(:invoice, :pending, :with_transactions, vendor: @vendor_user, transaction_count: 1, amount_per_transaction: 123.45)
      pay_invoice!(invoice, actor: admin, payment_method: 'check', check_number: 'CHK-5521', payment_reference: nil,
                            gad_invoice_reference: 'GAD-8812', payment_notes: 'Internal: cleared early')
      shared = ['Invoice number', invoice.invoice_number, number_to_currency(123.45), 'Check', 'CHK-5521', 'GAD-8812',
                I18n.l(Date.current, format: :long)]

      get vendor_portal_invoice_url(invoice)
      assert_response :success
      shared.each { |fact| assert_match fact, response.body }
      ['Recorded by', 'Rhea Ledger', 'Internal: cleared early'].each { |fact| assert_no_match fact, response.body }

      sign_in_with_headers(admin)
      get admin_invoice_url(invoice)
      assert_response :success
      (shared + ['Recorded by', 'Rhea Ledger', 'Internal: cleared early']).each { |fact| assert_match fact, response.body }
    end

    test 'a historical paid invoice shows unknown payment details as not recorded' do
      invoice = create(:invoice, :paid, vendor: @vendor_user, check_number: nil)

      get vendor_portal_invoice_url(invoice)

      assert_response :success
      assert_select 'dd', text: 'Not recorded'
    end

    test 'a suspended vendor keeps access to its invoices' do
      @vendor_user.update_column(:vendor_authorization_status, Users::Vendor.vendor_authorization_statuses[:suspended])

      get vendor_portal_invoice_url(@invoices.first)

      assert_response :success
      assert_match @invoices.first.invoice_number, response.body
    end

    test 'an invoice belonging to another vendor is not shown' do
      invoice_from_another_vendor = create(:invoice, vendor: create(:vendor_user))

      get vendor_portal_invoice_url(invoice_from_another_vendor)

      assert_redirected_to vendor_portal_invoices_url
    end
  end
end
