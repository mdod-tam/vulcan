# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class VoucherFulfillmentTest < ApplicationSystemTestCase
    test 'staff see a purchase\'s packages and fulfillment history on the voucher page' do
      vendor = create(:vendor, :approved, business_name: 'Accessible Phones Co')
      voucher = create(:voucher, :active, vendor: vendor)
      purchase = create(:voucher_transaction, voucher: voucher, vendor: vendor)
      service = VoucherTransactions::FulfillmentService.new(transaction: purchase, actor: vendor)
      shipment = service.add_shipment!(attributes: { 'tracking_number' => 'AAA111', 'dispatched_on' => '9/9/2026' }, expected_version: 0)
      service.correct_shipment!(shipment_id: shipment.id, attributes: { 'tracking_number' => 'AAA112' },
                                expected_lock_version: shipment.lock_version)

      system_test_sign_in(create(:admin))
      visit admin_voucher_path(voucher)

      assert_text 'Tracking number: AAA112'
      assert_text 'Tracking available for 1 package'
      assert_text 'Shipment Corrected'
      take_screenshot('admin-voucher-fulfillment', html: true, full: true)
    end
  end
end
