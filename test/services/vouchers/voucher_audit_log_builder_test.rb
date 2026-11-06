# frozen_string_literal: true

require 'test_helper'

module Vouchers
  class VoucherAuditLogBuilderTest < ActiveSupport::TestCase
    setup { ensure_system_audit_actor! }

    test 'deduplicated logs return the voucher\'s events instead of failing quietly' do
      voucher = create(:voucher, :active)
      AuditEventService.log(action: 'voucher_cancelled', actor: create(:admin), auditable: voucher,
                            metadata: { voucher_id: voucher.id, notes: 'Cancelled' })

      builder = VoucherAuditLogBuilder.new(voucher)

      assert_includes builder.build_deduplicated_audit_logs.map(&:action), 'voucher_cancelled'
      assert_empty builder.errors
    end

    test 'rapid financial mutations retain their owned events in the visible history' do
      actor = create(:admin)
      vendor = create(:vendor, :approved)
      voucher = create(:voucher, initial_value: 500, remaining_value: 500)

      freeze_time do
        2.times { voucher.redeem!(100, vendor) }
        voucher.cancel!(actor: actor)
        Current.set(user: actor) { voucher.update!(status: :active) }
        voucher.cancel!(actor: actor)

        events = VoucherAuditLogBuilder.new(voucher).build_deduplicated_audit_logs
        actions = events.map(&:action)
        assert_equal 2, actions.count('voucher_redeemed')
        assert_equal 2, actions.count('status_changed_to_cancelled')
        assert_equal 2, actions.count('voucher_cancelled')
        assert_equal voucher.events.ids.sort, events.map(&:id).sort
      end
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
