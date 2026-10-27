# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    setup do
      @vendor = create(:vendor)
      Current.test_user_id = nil
      ENV['TEST_USER_ID'] = nil
      cookies.delete(:session_token)
      @authenticated_user = nil
    end

    teardown do
      Current.test_user_id = nil
      ENV['TEST_USER_ID'] = nil
      cookies.delete(:session_token)
      reset!
    end

    test 'dashboard requires authentication' do
      sign_out
      Current.test_user_id = nil
      ENV['TEST_USER_ID'] = nil
      cookies.delete(:session_token)
      reset!

      get vendor_portal_dashboard_path
      assert_response :redirect
    end

    test 'gets show when authenticated' do
      sign_in_with_headers(@vendor)
      get vendor_portal_dashboard_path
      assert_response :success
    end
  end
end
