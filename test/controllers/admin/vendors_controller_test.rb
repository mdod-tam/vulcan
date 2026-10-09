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

    test 'edit shows sign-in email and phone read-only and saves the approval status' do
      vendor = create(:vendor, :approved)

      get edit_admin_vendor_path(vendor)

      assert_response :success
      assert_select 'input[name$="[email]"]', count: 0
      assert_select 'input[name$="[phone]"]', count: 0
      assert_select 'select[name$="[w9_status]"]', count: 0
      assert_select "a[href='#{edit_admin_user_path(vendor)}']"
      assert_select "form[action='#{admin_vendor_path(vendor)}'] select[name='vendor[vendor_authorization_status]']"

      patch admin_vendor_path(vendor), params: { vendor: { vendor_authorization_status: 'suspended' } }

      assert_redirected_to admin_vendor_path(vendor)
      assert vendor.reload.vendor_suspended?
      assert Event.exists?(auditable: vendor, action: 'vendor_updated')
    end

    test 'approval is granted only with an approved W9, and an approved vendor keeps it while a new W9 is reviewed' do
      vendor = create(:vendor, :approved)
      vendor.update_columns(vendor_authorization_status: Users::Vendor.vendor_authorization_statuses[:pending],
                            w9_status: Users::Vendor.w9_statuses[:pending_review])

      patch admin_vendor_path(vendor), params: { vendor: { vendor_authorization_status: 'approved' } }

      assert_response :unprocessable_content
      assert_match 'cannot be set to Approved until the W9 is approved', response.body
      assert vendor.reload.vendor_pending?

      vendor.update_columns(vendor_authorization_status: Users::Vendor.vendor_authorization_statuses[:approved])
      patch admin_vendor_path(vendor), params: { vendor: { business_name: 'Renamed Supply' } }

      assert_redirected_to admin_vendor_path(vendor)
      assert_equal 'Renamed Supply', vendor.reload.business_name
      assert vendor.vendor_approved?
    end
  end
end
