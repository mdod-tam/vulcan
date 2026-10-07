# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class VendorRoleConversionTest < ApplicationSystemTestCase
    test 'converting a vendor asks for confirmation; dismissing keeps the vendor' do
      vendor = create(:vendor, :approved, :with_w9, business_name: 'Accessible Phones Co')
      system_test_sign_in(create(:admin))
      install_stimulus_error_reporting
      visit admin_users_path(q: vendor.email)

      message = dismiss_confirm { select 'Users::Trainer', from: "role_#{vendor.id}" }
      assert_match(/may lose their W9 and transaction history/, message)
      assert_select "role_#{vendor.id}", selected: 'Users::Vendor'
      assert_equal 'Users::Vendor', User.find(vendor.id).type
      take_screenshot('admin-vendor-conversion-dismissed', html: true)

      accept_confirm { select 'Users::Trainer', from: "role_#{vendor.id}" }
      assert_select "role_#{vendor.id}", selected: 'Users::Trainer'
      assert_equal 'Users::Trainer', User.find(vendor.id).type
      assert_nil User.find(vendor.id).business_name
    end
  end
end
