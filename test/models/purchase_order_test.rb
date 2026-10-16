# frozen_string_literal: true

require 'test_helper'

class PurchaseOrderTest < ActiveSupport::TestCase
  test 'shipment summary follows device states from empty through partial and complete shipment' do
    order = create(:purchase_order)
    assert_equal 'No equipment currently linked', order.shipment_status
    first = create(:equipment_item, purchase_order: order, tracking_number: 'Label only')
    second = create(:equipment_item, purchase_order: order)
    assert_equal 'Awaiting Shipment', order.reload.shipment_status

    first.update!(shipped_at: Date.current)
    assert_equal 'Partially Shipped', order.reload.shipment_status

    second.update!(shipped_at: Date.current, tracking_number: 'Sent package')
    assert_equal 'Shipped', order.reload.shipment_status
  end
end
