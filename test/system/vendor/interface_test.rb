# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class InterfaceTest < ApplicationSystemTestCase
    setup do
      FeatureFlag.enable!(:vouchers_enabled)
      @vendor = create(:vendor, :approved)
      @voucher = create(:voucher, :active, vendor: @vendor, initial_value: 100)
      @product = create(:product)
      system_test_sign_in(@vendor)
    end

    test 'dashboard offers processing to an authorized vendor' do
      visit vendor_portal_dashboard_path
      assert_selector 'h1', text: 'Vendor Dashboard'
      assert_text 'Business Information'
      assert_text 'Recent Transactions'
      assert_text 'You are ready to redeem vouchers'
      assert_link 'Process Voucher'
    end

    test 'normal navigation verifies identity and redeems a voucher' do
      click_link 'Vouchers'
      fill_in 'Voucher Code', with: @voucher.code
      click_button 'Verify Voucher'
      assert_text 'Identity Verification'
      fill_in 'date_of_birth', with: @voucher.application.user.date_of_birth.strftime('%m/%d/%Y')
      click_button 'Verify Identity'
      assert_text 'Voucher Redemption'
      fill_in 'Redemption Amount', with: '50.00'
      check "product_#{@product.id}"
      click_button 'Process Redemption'
      assert_text 'Voucher successfully processed'
      assert_equal 50, @voucher.reload.remaining_value
      assert_equal [@product.id], @vendor.voucher_transactions.sole.products.pluck(:id)
      take_screenshot('vendor-interface-redemption-complete', html: true, full: true)
    end

    test 'invalid voucher lookup returns a visible error' do
      click_link 'Vouchers'
      fill_in 'Voucher Code', with: 'INVALID-CODE'
      click_button 'Verify Voucher'
      assert_text 'Invalid voucher code'
      assert_current_path vendor_portal_vouchers_path, ignore_query: true
    end

    test 'transaction rows display the vendor selected purchases' do
      create_list(:voucher_transaction, 3, vendor: @vendor)
      visit vendor_portal_transactions_path
      assert_selector 'h1', text: 'Transaction History'
      assert_selector 'table tbody tr', count: 3
      assert_text '3 purchases totaling'
    end

    test 'custom date filters preserve their dates in the complete export link' do
      dates = { period: 'custom', start_date: '10/01/2026', end_date: '10/09/2026' }
      visit vendor_portal_transactions_path
      select 'Custom Range', from: 'Time Period'
      fill_in 'Start Date', with: dates[:start_date]
      fill_in 'End Date', with: dates[:end_date]
      click_button 'Apply Filters'
      assert_field 'Start Date', with: dates[:start_date], visible: true
      assert_field 'End Date', with: dates[:end_date], visible: true
      export_params = Rack::Utils.parse_nested_query(URI.parse(find_link('Export CSV')[:href]).query)
      dates.each { |key, value| assert_equal value, export_params[key.to_s] }
      assert_not export_params.key?('page')
    end

    test 'paid invoice details show the recorded payment' do
      invoice = create(:invoice, :paid, :with_transactions, vendor: @vendor)
      visit vendor_portal_invoice_path(invoice)
      assert_text invoice.invoice_number
      assert_text 'Paid'
    end

    test 'a pending vendor sees the separate program authorization blocker' do
      @vendor.update!(vendor_authorization_status: :pending)
      visit vendor_portal_dashboard_path
      assert_text 'W9 approved; vendor authorization is still pending'
      assert_no_link 'Process Voucher'
      assert_selector '[data-vendor-onboarding-state="awaiting_authorization"]'
    end
  end
end
