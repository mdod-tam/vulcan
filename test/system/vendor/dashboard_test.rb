# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class DashboardTest < ApplicationSystemTestCase
    include SystemTestAuthentication

    setup do
      @vendor = create(:vendor, :approved)
    end

    # Signs in for real. Authentication runs earlier in the controller chain than a stubbed current_user,
    # so a stub would only reach the sign-in page.
    test 'chart has proper accessibility attributes' do
      system_test_sign_in(@vendor)
      visit vendor_portal_dashboard_path
      assert_selector 'h2#monthly-totals-heading'

      assert_selector "table#monthly-totals-table[aria-labelledby='monthly-totals-heading']"
      assert_selector 'table#monthly-totals-table caption.sr-only'

      assert_selector '#chart-description.sr-only'

      assert_selector "button[data-chart-toggle-target='button']"

      # The chart container is hidden by default.
      assert_selector '#monthly-totals-chart', visible: :all
    end
  end
end
