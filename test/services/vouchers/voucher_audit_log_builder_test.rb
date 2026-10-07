# frozen_string_literal: true

require 'test_helper'

module Vouchers
  class VoucherAuditLogBuilderTest < ActiveSupport::TestCase
    test 'deduplicated logs return the voucher\'s events instead of failing quietly' do
      voucher = create(:voucher, :active)
      AuditEventService.log(action: 'voucher_updated', actor: create(:admin), auditable: voucher,
                            metadata: { voucher_id: voucher.id, changes: { 'notes' => [nil, 'Checked'] } })

      builder = VoucherAuditLogBuilder.new(voucher)

      assert_includes builder.build_deduplicated_audit_logs.map(&:action), 'voucher_updated'
      assert_empty builder.errors
    end

    test 'fulfillment changes made within one minute all stay in the deduplicated log' do
      vendor = create(:vendor, :approved)
      voucher = create(:voucher, :active, vendor: vendor)
      purchase = create(:voucher_transaction, voucher: voucher, vendor: vendor)
      service = VoucherTransactions::FulfillmentService.new(transaction: purchase, actor: vendor)

      freeze_time do
        service.add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)
        shipment = service.add_shipment!(attributes: { 'tracking_number' => 'BBB222' }, expected_version: 1)
        2.times do |index|
          service.correct_shipment!(shipment_id: shipment.id, attributes: { 'tracking_number' => "BBB22#{index + 3}" },
                                    expected_lock_version: shipment.reload.lock_version)
        end
      end

      actions = VoucherAuditLogBuilder.new(voucher).build_deduplicated_audit_logs.map(&:action)
      assert_equal 2, actions.count('shipment_added')
      assert_equal 2, actions.count('shipment_corrected')
    end
  end
end
