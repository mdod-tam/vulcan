# frozen_string_literal: true

require 'test_helper'
require 'csv'

module Admin
  class InvoicesControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      @vendor = create(:vendor, :approved, business_name: 'Ray Supply')
      @invoice = create(:invoice, :pending, :with_transactions, vendor: @vendor, transaction_count: 2, amount_per_transaction: 40)
      sign_in_for_integration_test(@admin)
    end

    test 'approving and then recording a payment, each against the status the page showed' do
      patch approve_admin_invoice_path(@invoice), params: { expected_status: 'invoice_pending' }
      assert_redirected_to admin_invoice_path(@invoice)
      assert @invoice.reload.status_invoice_approved?

      patch record_payment_admin_invoice_path(@invoice), params: payment_form(payment_method: 'check', check_number: 'CHK-77')

      assert_redirected_to admin_invoice_path(@invoice)
      @invoice.reload
      assert @invoice.status_invoice_paid?
      assert_equal ['CHK-77', @admin], [@invoice.check_number, @invoice.paid_by]
    end

    test 'an incomplete payment re-renders the form with the errors and the entered values' do
      approve_invoice!(@invoice, actor: @admin)

      patch record_payment_admin_invoice_path(@invoice), params: payment_form(payment_method: 'eft', payment_reference: '',
                                                                              gad_invoice_reference: 'GAD-KEEP')

      assert_response :unprocessable_content
      assert_select '#payment-errors li', text: "Payment reference can't be blank"
      assert_select 'input[name="payment[gad_invoice_reference]"][value="GAD-KEEP"]'
      assert @invoice.reload.status_invoice_approved?
    end

    test 'a payment method outside the list is refused like any other invalid detail' do
      approve_invoice!(@invoice, actor: @admin)

      patch record_payment_admin_invoice_path(@invoice), params: payment_form(payment_method: 'wire')

      assert_response :unprocessable_content
      assert_select '#payment-errors li', text: 'Payment method is not included in the list'
      assert @invoice.reload.status_invoice_approved?
    end

    test 'a stale form is refused and says what the invoice is now' do
      pay_invoice!(@invoice, actor: @admin, payment_reference: 'EFT-FIRST')

      patch record_payment_admin_invoice_path(@invoice), params: payment_form(payment_reference: 'EFT-SECOND')

      assert_redirected_to admin_invoice_path(@invoice)
      assert_match 'it is now paid. Nothing was changed', flash[:alert]
      assert_equal 'EFT-FIRST', @invoice.reload.payment_reference
    end

    test 'withdrawing keeps the invoice and releases its purchases' do
      patch withdraw_admin_invoice_path(@invoice), params: { expected_status: 'invoice_pending', reason: 'Wrong vendor' }

      assert_redirected_to admin_invoice_path(@invoice)
      assert @invoice.reload.status_invoice_cancelled?
      assert_empty @invoice.voucher_transactions
      follow_redirect!
      assert_match 'Withdrawn', response.body
    end

    test 'a correction note is kept in the invoice history' do
      pay_invoice!(@invoice, actor: @admin)

      post correction_note_admin_invoice_path(@invoice), params: { reference: 'JE-9', note: 'Deposit reversed' }

      assert_redirected_to admin_invoice_path(@invoice)
      follow_redirect!
      assert_match 'Reference: JE-9', response.body
      assert_match 'Note: Deposit reversed', response.body
    end

    test 'invoice now bills one vendor through the scheduled path and lists nothing left to bill' do
      purchase = create(:voucher_transaction, vendor: @vendor, amount: 15, processed_at: 2.days.ago)

      get admin_invoices_path
      assert_select 'section[aria-labelledby="not-invoiced-heading"]', text: /Ray Supply.*\$15\.00 in 1 voucher redemption/m

      post generate_admin_invoices_path, params: { vendor_id: @vendor.id }

      assert_redirected_to admin_invoices_path
      assert_equal 'Invoice created for Ray Supply.', flash[:notice]
      assert purchase.reload.invoice
    end

    test 'invoice now reports a run already in progress instead of a failure' do
      create(:voucher_transaction, vendor: @vendor, amount: 15, processed_at: 2.days.ago)
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      other_run = PG.connect(dbname: config[:database], host: config[:host], port: config[:port],
                             user: config[:username], password: config[:password])
      other_run.exec("SELECT pg_advisory_lock(#{Invoices::GenerationService::LOCK_KEY})")

      post generate_admin_invoices_path, params: { vendor_id: @vendor.id }

      assert_equal 'Invoicing is already running. Try again in a few minutes.', flash[:alert]
    ensure
      other_run&.close
    end

    test 'a failed vendor is listed for retry until a retry succeeds' do
      InvoiceGenerationFailure.record!(vendor_id: @vendor.id, cutoff: Time.current, error: RuntimeError.new('boom'))
      create(:voucher_transaction, vendor: @vendor, amount: 15, processed_at: 2.days.ago)

      get admin_invoices_path
      assert_select 'section[aria-labelledby="failures-heading"] form[aria-label="Retry invoicing for Ray Supply"]'

      post generate_admin_invoices_path, params: { vendor_id: @vendor.id }
      get admin_invoices_path
      assert_select 'section[aria-labelledby="failures-heading"]', count: 0
    end

    test 'status and date filters, with the date basis explicit' do
      paid = create(:invoice, :pending, vendor: @vendor, start_date: Time.zone.local(2026, 3, 1), end_date: Time.zone.local(2026, 3, 15))
      pay_invoice!(paid, actor: @admin, payment_date: Date.new(2026, 9, 2))

      get admin_invoices_path, params: { status: 'paid', date_basis: 'period', from: '03/10/2026', through: '03/10/2026' }
      assert_equal [paid.invoice_number], listed_numbers - fixture_numbers

      get admin_invoices_path, params: { status: 'paid', date_basis: 'payment', from: '03/10/2026', through: '03/10/2026' }
      assert_empty listed_numbers

      get admin_invoices_path, params: { date_basis: 'payment', from: '09/02/2026', through: '09/02/2026' }
      assert_equal [paid.invoice_number], listed_numbers

      get admin_invoices_path, params: { status: 'pending', vendor_id: @vendor.id }
      assert_equal [@invoice.invoice_number], listed_numbers

      get admin_invoices_path, params: { from: '13/45/2026' }
      assert_match 'From date is not a valid date', flash[:alert]
    end

    test 'the CSV exports every matching invoice, beyond one page, in page order' do
      26.times { |i| create(:invoice, :pending, vendor: @vendor, start_date: Time.zone.local(2025, 1, 1) + i.days, end_date: Time.zone.local(2025, 1, 2) + i.days) }
      create(:invoice, :cancelled, vendor: @vendor)

      get admin_invoices_path, params: { status: 'pending', vendor_id: @vendor.id }
      page_numbers = listed_numbers
      assert_equal 25, page_numbers.size

      get admin_invoices_path(format: :csv), params: { status: 'pending', vendor_id: @vendor.id }
      rows = CSV.parse(response.body, headers: true)

      assert_equal 27, rows.size
      assert_equal(page_numbers, rows.first(25).pluck('Invoice Number'))
      assert_equal ['Awaiting approval'], rows.pluck('Status').uniq
    end

    test 'the CSV neutralizes vendor-entered text that a spreadsheet would run as a formula' do
      @vendor.update_column(:business_name, '=HYPERLINK("http://example.test","Ray")')

      get admin_invoices_path(format: :csv), params: { vendor_id: @vendor.id }

      assert_equal ["'=HYPERLINK(\"http://example.test\",\"Ray\")"], CSV.parse(response.body, headers: true).pluck('Vendor')
    end

    test 'staff who are not admins cannot reach invoices' do
      sign_in_for_integration_test(create(:trainer))

      get admin_invoices_path
      assert_response :redirect
      patch approve_admin_invoice_path(@invoice), params: { expected_status: 'invoice_pending' }
      assert @invoice.reload.status_invoice_pending?
    end

    private

    def payment_form(**overrides)
      { expected_status: 'invoice_approved',
        payment: { payment_date: Date.current.strftime('%m/%d/%Y'), payment_method: 'eft', payment_reference: 'EFT-1',
                   check_number: '', gad_invoice_reference: 'GAD-1', payment_notes: '' }.merge(overrides) }
    end

    def fixture_numbers
      Invoice.where.not(vendor: @vendor).pluck(:invoice_number)
    end

    def listed_numbers
      css_select('section[aria-labelledby="invoices-heading"] tbody tr td:first-child a').map { |link| link.text.strip }
    end
  end
end
