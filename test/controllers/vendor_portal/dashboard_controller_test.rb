# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    def setup
      # Use factory instead of fixture
      @vendor = create(:vendor, :approved)

      # Set standard test headers
      @headers = {
        'HTTP_USER_AGENT' => 'Rails Testing',
        'REMOTE_ADDR' => '127.0.0.1'
      }

      # Use the sign_in helper from test_helper.rb
      sign_in_for_integration_test(@vendor)
    end

    def test_get_show
      get vendor_portal_dashboard_path
      assert_response :success
      # Instead of checking assigns which is deprecated in newer Rails,
      # check for content in the response body that indicates the page loaded correctly
      assert_match(/dashboard/i, response.body)
    end

    test 'monthly totals chart is explicitly currency formatted' do
      get vendor_portal_dashboard_path
      assert_response :success

      assert_select '#monthly-totals-chart [data-controller="chart"][data-chart-format-value="currency"]'
    end
  end
end
