# frozen_string_literal: true

require 'test_helper'

module Admin
  class VouchersIndexTest < ActionDispatch::IntegrationTest
    setup do
      sign_in_for_integration_test(create(:admin), bypass_mfa_enrollment: true)
    end

    test 'voucher detail shows separate purchases and the required status event' do
      actor = create(:admin)
      vendor = create(:vendor, :approved)
      voucher = create(:voucher, initial_value: 500, remaining_value: 500)
      2.times { voucher.redeem!(100, vendor) }
      voucher.cancel!(actor: actor)

      get admin_voucher_path(voucher)

      assert_response :success
      assert_select 'div.text-sm.text-gray-500', text: /\AVoucher Redeemed\s+by/, count: 2
      assert_select 'div.text-sm.text-gray-500', text: /\AStatus Changed To Cancelled\s+by/, count: 1
    end

    test 'an assigned voucher links its vendor to the admin vendor page and an unassigned one is labeled' do
      vendor = create(:vendor, :approved, business_name: 'Linked Index Vendor')
      create(:voucher, :active, vendor: vendor)
      create(:voucher, :active, vendor: nil)

      get admin_vouchers_path

      assert_response :success
      assert_select 'tbody tr', count: 2
      assert_select 'tbody td a[href=?]', admin_vendor_path(vendor), text: 'Linked Index Vendor', count: 1
      assert_select 'tbody td span', text: 'Unassigned', count: 1
    end

    test 'the vendor filter keeps only that vendor\'s vouchers and links the vendor' do
      vendor = create(:vendor, :approved, business_name: 'Filtered Index Vendor')
      other = create(:vendor, :approved, business_name: 'Other Index Vendor')
      create(:voucher, :active, vendor: vendor)
      create(:voucher, :active, vendor: other)

      get admin_vouchers_path, params: { vendor_id: vendor.id }

      assert_response :success
      assert_select 'tbody tr', count: 1
      assert_select 'tbody td a[href=?]', admin_vendor_path(vendor), text: 'Filtered Index Vendor', count: 1
      assert_select 'tbody td a[href=?]', admin_vendor_path(other), count: 0
    end
  end
end
