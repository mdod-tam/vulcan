# frozen_string_literal: true

require 'test_helper'

module Admin
  # Staff answer "where is this package?" from the admin voucher page.
  class VoucherFulfillmentVisibilityTest < ActionDispatch::IntegrationTest
    test 'the voucher page shows each purchase\'s packages and fulfillment history' do
      admin = create(:admin)
      vendor = create(:vendor, :approved)
      voucher = create(:voucher, :active, vendor: vendor)
      purchase = create(:voucher_transaction, voucher: voucher, vendor: vendor)
      service = VoucherTransactions::FulfillmentService.new(transaction: purchase, actor: vendor)
      shipment = service.add_shipment!(attributes: { 'tracking_number' => 'AAA111', 'dispatched_on' => '9/9/2026' }, expected_version: 0)
      service.correct_shipment!(shipment_id: shipment.id, attributes: { 'tracking_number' => 'AAA112' },
                                expected_lock_version: shipment.lock_version)

      sign_in_for_integration_test(admin)
      get admin_voucher_path(voucher)

      assert_response :success
      assert_select 'li', text: /Tracking number: AAA112/
      assert_select 'li', text: /Vendor-reported ship date: September 09, 2026/
      assert_select 'span', text: 'Tracking available for 1 package'
      assert_match 'Shipment Added', response.body
      assert_match 'Shipment Corrected', response.body
      assert_select 'div.text-gray-500', text: /Tracking number:\s*AAA111\s*→\s*AAA112/
    end
  end
end
