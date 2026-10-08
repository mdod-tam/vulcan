# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class VendorEditTest < ApplicationSystemTestCase
    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      @vendor = create(:vendor, :approved, business_name: 'Ray Supply')
      sign_in(@admin)
    end

    test 'staff suspend a vendor; sign-in email and phone are read-only' do
      visit admin_vendor_path(@vendor)
      click_link href: edit_admin_vendor_path(@vendor)

      assert_text @vendor.email
      assert_link 'Change them in the user editor'
      assert_no_field 'Email'
      take_screenshot('admin-vendor-edit', html: true)

      select 'Suspended', from: 'Vendor approval'
      click_on 'Update Vendor'

      assert_text 'Vendor was successfully updated.'
      assert @vendor.reload.vendor_suspended?
    end
  end
end
