# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class TransactionsControllerTest < ActionDispatch::IntegrationTest
    # Assuming AuthenticationTestHelper exists and provides sign_in_with_headers and assert_authenticated
    # If not, this helper might need to be created or adjusted based on the actual authentication setup.
    # For now, we'll assume it exists as per the user's example.
    include AuthenticationTestHelper

    setup do
      @vendor_user = create(:vendor_user) # Use FactoryBot to create a vendor user
      sign_in_with_headers(@vendor_user) # Sign in the vendor user
      assert_authenticated(@vendor_user) # Verify authentication
    end

    test 'should show transactions index with pagination' do
      # Using vendor_portal_transactions_url route
      # Create multiple transactions to test pagination
      create_list(:voucher_transaction, 30, vendor: @vendor_user)
      get vendor_portal_transactions_url
      assert_response :success
      # Assert presence of transaction data and pagination links
      assert_select 'h1', 'Transaction History' # Updated assertion
      # Assert presence of the pagination nav element
      assert_select 'nav[aria-label="Transaction pages"]'
      # Assertions to check for the correct number of transactions per page (default is 20 for Pagy)
      assert_select 'table.min-w-full tbody tr', count: 20 # Expect 20 transactions on the first page
    end

    test 'today uses Eastern processed time with an exclusive next midnight and a stable order' do
      travel_to Time.zone.local(2026, 10, 9, 12) do
        before = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 8, 23, 59, 59))
        first = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 9), created_at: 2.months.ago)
        tied = create(:voucher_transaction, vendor: @vendor_user, processed_at: first.processed_at, created_at: 3.months.ago)
        last = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 9, 23, 59, 59))
        after = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 10))

        get vendor_portal_transactions_url(period: 'today')

        assert_response :success
        assert_equal [last.id, tied.id, first.id], controller.instance_variable_get(:@transactions).map(&:id)
        assert_no_match before.reference_number, response.body
        assert_no_match after.reference_number, response.body
      end
    end

    test 'this week and this month select calendar periods instead of rolling intervals' do
      travel_to Time.zone.local(2026, 10, 9, 12) do
        september = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 9, 30, 23, 59, 59))
        month_start = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 1))
        week_start = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 5))
        week_end = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 11, 23, 59, 59))
        next_week = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 12))
        november = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 11, 1))

        get vendor_portal_transactions_url(period: 'week')
        assert_equal [week_end.id, week_start.id], controller.instance_variable_get(:@transactions).map(&:id)

        get vendor_portal_transactions_url(period: 'month')
        assert_equal [next_week.id, week_end.id, week_start.id, month_start.id], controller.instance_variable_get(:@transactions).map(&:id)
        assert_no_match september.reference_number, response.body
        assert_no_match november.reference_number, response.body
      end
    end

    test 'a custom range uses the shared date parser and includes the entire Eastern DST day' do
      first = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.utc(2026, 11, 1, 4))
      last = create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.utc(2026, 11, 2, 4, 59, 59))
      create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.utc(2026, 11, 2, 5))

      get vendor_portal_transactions_url(period: 'custom', start_date: '11/1/2026', end_date: '2026-11-01')

      assert_response :success
      assert_equal [last.id, first.id], controller.instance_variable_get(:@transactions).map(&:id)
    end

    test 'totals and the complete CSV share the filtered query across pages and retain filters in links' do
      matches = create_list(:voucher_transaction, 23, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 9, 12), amount: 40)
      create(:voucher_transaction, vendor: @vendor_user, processed_at: Time.zone.local(2026, 10, 8), amount: 90)
      create(:voucher_transaction, vendor: create(:vendor_user), processed_at: matches.first.processed_at, amount: 120)
      filters = { period: 'custom', start_date: '10/09/2026', end_date: '10/09/2026', needs_shipping_details: '1' }

      get vendor_portal_transactions_url(**filters, page: 2)

      assert_response :success
      assert_select 'table tbody tr', count: 3
      assert_equal 23, controller.instance_variable_get(:@transaction_count)
      assert_equal 920, controller.instance_variable_get(:@total_amount)
      assert_select 'nav[aria-label="Transaction pages"] [aria-current="page"]', text: '2'
      assert_select 'nav a[rel="prev"]' do |links|
        query = Rack::Utils.parse_nested_query(URI.parse(links.first['href']).query)
        assert_equal filters.stringify_keys.merge('page' => '1'), query
      end
      assert_select 'a', text: 'Export CSV' do |links|
        query = Rack::Utils.parse_nested_query(URI.parse(links.first['href']).query)
        assert_equal filters.stringify_keys, query
      end
      assert_select 'form input[name="page"]', count: 0

      get vendor_portal_transactions_url(**filters, page: 2, format: :csv)

      assert_response :success
      rows = CSV.parse(response.body, headers: true)
      assert_equal matches.map(&:reference_number).sort, rows.pluck('Reference Number').sort
      assert_equal(920, rows.sum { |row| row['Amount'].to_d })
    end

    test 'incomplete invalid and reversed custom ranges remain visible and cannot export all history' do
      purchase = create(:voucher_transaction, vendor: @vendor_user)
      [
        ['10/09/2026', '', 'Enter both a start date and an end date.'],
        ['13/45/2026', '10/09/2026', 'Start date is invalid. Use MM/DD/YYYY.'],
        ['10/09/2026', 'yesterday', 'End date is invalid. Use MM/DD/YYYY.'],
        ['10/10/2026', '10/09/2026', 'Start date must be on or before the end date.']
      ].each do |first, last, error|
        filters = { period: 'custom', start_date: first, end_date: last }
        get vendor_portal_transactions_url(**filters)
        assert_response :unprocessable_content
        assert_select '[role="alert"]', text: /#{Regexp.escape(error)}/
        assert_select('input[name="start_date"]') { |inputs| assert_equal first, inputs.first['value'].to_s }
        assert_select('input[name="end_date"]') { |inputs| assert_equal last, inputs.first['value'].to_s }
        assert_select 'select[name="period"] option[value="custom"][selected]'
        assert_select 'table tbody tr', count: 0
        assert_equal 0, controller.instance_variable_get(:@total_amount)

        get vendor_portal_transactions_url(**filters, format: :csv)
        assert_response :unprocessable_content
        assert_match error, response.body
        assert_no_match purchase.reference_number, response.body
      end
    end

    test 'should not show transactions belonging to another vendor' do
      another_vendor_user = create(:vendor_user)
      create_list(:voucher_transaction, 5, vendor: another_vendor_user)

      get vendor_portal_transactions_url
      assert_response :success
      # Assert that only the current vendor's transactions are displayed
      # Since no transactions are created for the current vendor in this test, expect 0 rows.
      assert_select 'table.min-w-full tbody tr', count: 0
      # You might need more specific assertions to ensure the displayed transactions belong to @vendor_user
    end

    test 'the shipping filter narrows the list, its totals, and its pages, and rows show fulfillment' do
      needs_details = create(:voucher_transaction, vendor: @vendor_user, amount: 40)
      shipped = create(:voucher_transaction, vendor: @vendor_user, amount: 60)
      VoucherTransactions::FulfillmentService.new(transaction: shipped, actor: @vendor_user)
                                             .add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)

      get vendor_portal_transactions_url(needs_shipping_details: '1')

      assert_response :success
      assert_select 'table.min-w-full tbody tr', count: 1
      assert_select 'tbody a', text: needs_details.reference_number
      assert_select 'tbody', text: /Waiting for shipping details/
      assert_equal 1, controller.instance_variable_get(:@transaction_count)
      assert_equal 40, controller.instance_variable_get(:@total_amount)

      get vendor_portal_transactions_url
      assert_select 'tbody', text: /Tracking available for 1 package/
    end

    test 'a purchase page shows its packages; another vendor\'s purchase is not found' do
      purchase = create(:voucher_transaction, vendor: @vendor_user)
      VoucherTransactions::FulfillmentService.new(transaction: purchase, actor: @vendor_user)
                                             .add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)

      get vendor_portal_transaction_url(purchase)
      assert_response :success
      assert_select 'h2', 'Packages'
      assert_select 'li', text: /AAA111/

      get vendor_portal_transaction_url(create(:voucher_transaction, vendor: create(:vendor_user)))
      assert_response :not_found
    end

    test 'multiple packages do not multiply a purchase in the total or CSV' do
      purchase = create(:voucher_transaction, vendor: @vendor_user, amount: 75)
      service = VoucherTransactions::FulfillmentService.new(transaction: purchase, actor: @vendor_user)
      service.add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)
      service.add_shipment!(attributes: { 'tracking_number' => 'BBB222' }, expected_version: 1)

      get vendor_portal_transactions_url

      assert_response :success
      assert_equal 1, controller.instance_variable_get(:@transaction_count)
      assert_equal 75, controller.instance_variable_get(:@total_amount)
      assert_select 'table tbody tr', count: 1

      get vendor_portal_transactions_url(format: :csv)

      rows = CSV.parse(response.body, headers: true)
      assert_equal 1, rows.size
      assert_equal purchase.reference_number, rows.sole['Reference Number']
      assert_equal 75, rows.sole['Amount'].to_d
    end

    test 'choosing local pickup records the mode; a stale form is refused' do
      purchase = create(:voucher_transaction, vendor: @vendor_user)

      patch vendor_portal_transaction_url(purchase), params: { fulfillment_mode: 'local_pickup', fulfillment_version: 0 }
      assert_redirected_to vendor_portal_transaction_path(purchase)
      assert purchase.reload.fulfillment_local_pickup?

      patch vendor_portal_transaction_url(purchase), params: { fulfillment_mode: 'shipping', fulfillment_version: 0 }
      assert_redirected_to vendor_portal_transaction_path(purchase)
      assert_match(/Someone else changed this purchase/, flash[:alert])
      assert purchase.reload.fulfillment_local_pickup?
    end

    test 'only shipping or pickup can be chosen' do
      purchase = create(:voucher_transaction, vendor: @vendor_user)

      patch vendor_portal_transaction_url(purchase), params: { fulfillment_mode: 'unspecified', fulfillment_version: 0 }

      assert_equal 'Choose shipping or local pickup.', flash[:alert]
      assert_equal 0, purchase.reload.fulfillment_version
    end

    test 'another vendor cannot change a purchase' do
      purchase = create(:voucher_transaction, vendor: create(:vendor_user))

      patch vendor_portal_transaction_url(purchase), params: { fulfillment_mode: 'local_pickup', fulfillment_version: 0 }

      assert_response :not_found
      assert purchase.reload.fulfillment_unspecified?
    end

    test 'each purchase shows its invoice number, a hold, or that it is not yet invoiced, on the page and in the CSV' do
      invoice = create(:invoice, :pending, :with_transactions, vendor: @vendor_user, transaction_count: 1)
      held = create(:voucher_transaction, vendor: @vendor_user)
      held.update_columns(billing_hold_at: Time.current, billing_hold_reason: 'Internal review note')
      create(:voucher_transaction, vendor: @vendor_user)

      get vendor_portal_transactions_url
      assert_select "a[href='#{vendor_portal_invoice_path(invoice)}']", text: invoice.invoice_number
      assert_match 'On hold — contact the program', response.body
      assert_match 'Not yet invoiced', response.body
      assert_no_match 'Internal review note', response.body

      get vendor_portal_transactions_url(format: :csv)
      rows = CSV.parse(response.body, headers: true)
      assert_equal ['Awaiting approval', 'Not yet invoiced', 'On hold'], rows.pluck('Billing').sort
      assert_equal([invoice.invoice_number], rows.filter_map { |row| row['Invoice Number'].presence })
    end
  end
end
