# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class ProfilesTest < ApplicationSystemTestCase
    setup do
      @vendor_user = create(:vendor, :approved, email_verified: true)
      system_test_sign_in(@vendor_user)
    end

    test 'profile editing keeps the tax ID and earlier terms acceptance' do
      visit edit_vendor_portal_profile_path
      assert_selector 'h1', text: 'Vendor Profile'
      accepted_at = @vendor_user.terms_accepted_at
      tax_id = @vendor_user.business_tax_id
      fill_in 'Business name', with: 'Updated Browser Vendor'
      assert_field 'users_vendor_business_tax_id', with: ''
      assert_no_field 'users_vendor_terms_accepted'
      fill_in 'Address Line 1', with: '123 Test Street'
      fill_in 'City', with: 'Baltimore'
      fill_in 'State', with: 'MD'
      fill_in 'Zip Code', with: '21201'
      fill_in 'Phone', with: '410-555-1234'
      click_button 'Save Changes'
      assert_text 'Profile updated successfully'
      assert_current_path vendor_portal_dashboard_path
      assert_equal 'Updated Browser Vendor', @vendor_user.reload.business_name
      assert_equal accepted_at, @vendor_user.terms_accepted_at
      assert_equal tax_id, @vendor_user.business_tax_id
      take_screenshot('vendor-profile-existing-acceptance-preserved', html: true, full: true)
    end
  end
end
