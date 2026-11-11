# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    setup do
      @vendor = create(:vendor)
      cookies.delete('session_token')
    end

    teardown do
      cookies.delete('session_token')
      reset!
    end

    test 'dashboard requires authentication' do
      sign_out
      cookies.delete('session_token')
      reset!

      get vendor_portal_dashboard_path
      assert_response :redirect
    end

    test 'gets show when authenticated' do
      sign_in_for_integration_test(@vendor, bypass_mfa_enrollment: true)
      get vendor_portal_dashboard_path
      assert_response :success
    end
  end
end
