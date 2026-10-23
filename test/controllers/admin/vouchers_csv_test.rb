# frozen_string_literal: true

require 'test_helper'
require 'csv'

module Admin
  class VouchersCsvTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'download preserves voucher columns and filters while escaping text and auditing the exported row count' do
      vendor_name = "  ＋SUM(1,2),\"vendor\"\nsecond line"
      vendor = create(:vendor, :approved, business_name: vendor_name)
      voucher = create(:voucher, :active, vendor: vendor, code: '=UNSAFE', initial_value: 125.50, remaining_value: 75.25)
      create(:voucher, :cancelled, vendor: vendor)
      create(:voucher, :active)

      assert_difference -> { Event.where(action: 'export_generated', user: @admin).count } do
        get admin_vouchers_path(format: :csv), params: { status: 'active', vendor_id: vendor.id }
      end

      assert_response :success
      rows = CSV.parse(response.body, headers: true)
      assert_equal ['Code', 'Status', 'Initial Value', 'Remaining Value', 'Vendor', 'Created At', 'Expiration Date', 'Last Transaction'], rows.headers
      assert_equal 1, rows.size
      assert_equal "'#{voucher.code}", rows.sole['Code']
      assert_equal "'#{vendor_name}", rows.sole['Vendor']
      assert_equal BigDecimal('125.50'), rows.sole['Initial Value'].to_d
      assert_equal BigDecimal('75.25'), rows.sole['Remaining Value'].to_d
      event = Event.where(action: 'export_generated', user: @admin).order(:id).last
      assert_equal({ 'export_type' => 'admin_vouchers', 'row_count' => 1, '__service_generated' => true }, event.metadata)
    end

    test 'an empty voucher download retains the empty response and records a zero-row export' do
      get admin_vouchers_path(format: :csv), params: { vendor_id: create(:vendor, :approved).id }

      assert_response :success
      assert_empty response.body
      event = Event.where(action: 'export_generated', user: @admin).order(:id).last
      assert_equal 0, event.metadata.fetch('row_count')
    end
  end
end
