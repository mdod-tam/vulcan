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
      assert_select 'nav.flex.items-center.justify-between'
      # Assertions to check for the correct number of transactions per page (default is 20 for Pagy)
      assert_select 'table.min-w-full tbody tr', count: 20 # Expect 20 transactions on the first page
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
  end
end
