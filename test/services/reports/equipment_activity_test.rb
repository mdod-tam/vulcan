# frozen_string_literal: true

require 'test_helper'

module Reports
  class EquipmentActivityTest < ActiveSupport::TestCase
    test 'separates shipment activity from orders sent in the period and counts partial orders once' do
      travel_to Time.zone.local(2026, 8, 20, 12) do
        older_order = create(:purchase_order, vendor_name: 'Harbor', sent_at: Date.new(2026, 5, 28))
        recent_order = create(:purchase_order, vendor_name: 'HARBOR', sent_at: Date.new(2026, 7, 6))
        old_shipment = create(:equipment_item, purchase_order: older_order, shipped_at: Date.new(2026, 6, 2), tracking_number: 'PAST-PO')
        create(:equipment_item, purchase_order: recent_order, shipped_at: Date.new(2026, 7, 8), tracking_number: 'RECENT-PO')
        create_pair(:equipment_item, purchase_order: recent_order)
        create(:equipment_item, purchase_order: older_order)
        create(:equipment_item, purchase_order: create(:purchase_order, vendor_name: 'Unsent', sent_at: nil), po_assigned_at: 6.days.ago)
        equipment_need = create(:equipment_need, remaining_quantity: 3, unfulfilled_since: 12.days.ago)
        bid = BidGroup.create!(number: 'BID-REPORT', created_at: 8.days.ago, purpose: :direct_to_constituents)
        bid.bid_group_lines.create!(equipment_need:, product: equipment_need.product, quantity: 1)

        actor = create(:admin)
        Event.create!(action: 'equipment_shipment_recorded', user: actor, auditable: old_shipment, created_at: Time.zone.local(2026, 6, 5),
                      metadata: { changes: { shipped_at: [nil, '2026-06-02'] } })
        Event.create!(action: 'equipment_item_corrected', user: actor, auditable: old_shipment, created_at: Time.zone.local(2026, 6, 7),
                      metadata: { changes: { shipped_at: { old: '2026-06-03', new: '2026-06-02' } } })

        report = EquipmentActivity.new(Period.new(3))
        assert_equal [1, 1, 0], report.shipment_counts
        assert_equal [5.0, 2.0, nil], report.ship_times
        assert_equal 3.5, report.average_ship_time
        assert_equal [['HARBOR', 2, 3.5]], report.volume_and_speed
        assert_equal [['HARBOR', 2, 3.5, 4.7, 3.0, 1]], report.vendor_shipping_times
        assert_equal [['HARBOR', 1, 2]], report.orders_by_vendor
        backlog = report.oldest_outstanding_orders
        assert_equal 2, backlog.total
        assert_equal [[older_order, 1, 84], [recent_order, 2, 45]], backlog.entries.map(&:deconstruct)
        assert_equal({ awaiting_bid: [2, 12], awaiting_award: [1, 8], awaiting_send: [1, 6],
                       awaiting_shipment: [2, 84], awaiting_delivery: [2, 79] }, report.open_work.transform_values(&:deconstruct))
      end
    end
  end
end
