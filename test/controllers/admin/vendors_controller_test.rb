# frozen_string_literal: true

require 'test_helper'

module Admin
  class VendorsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'index only links to W9 review when pending review vendor has an attached W9' do
      reviewable_vendor = create(:vendor, :with_w9, business_name: 'Attached W9 Vendor')
      drifted_vendor = create(:vendor, business_name: 'Missing W9 Vendor', w9_status: :pending_review)

      get admin_vendors_path

      assert_response :success
      assert_select "a[href='#{new_admin_vendor_w9_review_path(reviewable_vendor)}']", text: 'Review W9'
      assert_select "a[href='#{new_admin_vendor_w9_review_path(drifted_vendor)}']", text: 'Review W9', count: 0
    end
  end
end
