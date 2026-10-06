# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class DashboardTest < ApplicationSystemTestCase
    setup do
      # Create vendor with all necessary attributes for authentication
      @vendor = Users::Vendor.create!(
        email: 'test_vendor@example.com',
        password: 'password1234',
        first_name: 'Test',
        last_name: 'Vendor',
        business_name: 'Test Business',
        business_tax_id: '123456789',
        vendor_authorization_status: :approved,
        verified: true,
        email_verified: true,
        terms_accepted_at: 1.day.ago,
        w9_status: :approved
      )
    end

    test 'chart has proper accessibility attributes' do
      # Stub authentication for this accessibility-focused test
      VendorPortal::DashboardController.any_instance.stubs(:current_user).returns(@vendor)
      VendorPortal::DashboardController.any_instance.stubs(:authenticate_vendor!).returns(true)

      # Mock the vendor methods that the dashboard needs
      @vendor.stubs(:latest_transactions).returns(VoucherTransaction.none)
      @vendor.stubs(:pending_transaction_total).returns(0)
      @vendor.stubs(:total_transactions_by_period).returns({})
      @vendor.stubs(:vendor_pending?).returns(false)

      # Mock W9 form
      w9_mock = Object.new
      w9_mock.stubs(:attached?).returns(true)
      @vendor.stubs(:w9_form).returns(w9_mock)

      # Visit dashboard
      with_browser_rescue(max_retries: 3) do
        visit vendor_portal_dashboard_path
        wait_for_page_stable
      end

      # Check that the table has proper accessibility attributes
      assert_selector "table#monthly-totals-table[aria-labelledby='monthly-totals-heading']"
      assert_selector 'table#monthly-totals-table caption.sr-only'

      # Check that the chart description is present
      assert_selector '#chart-description.sr-only'

      # Check that the toggle button has proper accessibility attributes
      assert_selector "button[data-chart-toggle-target='button']"

      # Check that the chart container has an ID for ARIA controls (it's hidden by default)
      assert_selector '#monthly-totals-chart', visible: :all
    end
  end
end
