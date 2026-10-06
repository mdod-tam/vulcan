# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class DashboardTest < ApplicationSystemTestCase
    include SystemTestAuthentication

    setup do
      @vendor = create(:vendor, :approved)
    end

    # Signs in for real. Stubbing current_user on this controller never reached the dashboard:
    # authentication runs earlier in the controller chain, so the test only ever saw the sign-in page.
    test 'chart has proper accessibility attributes' do
      system_test_sign_in(@vendor)
      visit vendor_portal_dashboard_path
      assert_selector 'h2#monthly-totals-heading'

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
