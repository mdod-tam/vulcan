# frozen_string_literal: true

require 'test_helper'

class PurchaseOrderTest < ActiveSupport::TestCase
  test 'shipment summary follows device states from empty through partial and complete shipment' do
    order = create(:purchase_order)
    assert_equal 'No equipment currently linked', order.shipment_status
    first = create(:equipment_item, purchase_order: order, tracking_number: 'Label only')
    second = create(:equipment_item, purchase_order: order)
    assert_equal 'Shipping info needed', order.reload.shipment_status

    first.update!(shipped_at: Date.current)
    assert_equal 'Partially shipped', order.reload.shipment_status

    second.update!(shipped_at: Date.current, tracking_number: 'Sent package')
    assert_equal 'Shipment recorded', order.reload.shipment_status
  end

  test 'retiring received stock preserves the original acquisition completion' do
    order = program_stock_order(quantity: 1)
    receive_stock(order, quantity: 1)
    retire_stock(order.equipment_items.sole)

    assert_equal 'Received', order.reload.shipment_status
    assert_equal({ ordered: 1, received: 1, cancelled: 0, outstanding: 0 }, order.stock_receipt_counts.to_h)
  end

  test 'only unreceived cancellations reduce a stock orders outstanding acquisition balance' do
    order = program_stock_order(quantity: 3)
    receive_stock(order, quantity: 1)
    received = order.equipment_items.where.not(stock_received_on: nil).sole
    retire_stock(received)
    retire_stock(order.equipment_items.active.where(stock_received_on: nil).order(:id).first)

    assert_equal 'Partially received', order.reload.shipment_status
    assert_equal({ ordered: 3, received: 1, cancelled: 1, outstanding: 1 }, order.stock_receipt_counts.to_h)
    retire_stock(order.equipment_items.active.where(stock_received_on: nil).sole)
    assert_equal 'Closed with cancellations', order.reload.shipment_status
    assert_equal({ ordered: 3, received: 1, cancelled: 2, outstanding: 0 }, order.stock_receipt_counts.to_h)
  end

  test 'an entirely cancelled unreceived stock order never claims receipt' do
    order = program_stock_order(quantity: 1)
    retire_stock(order.equipment_items.sole)

    assert_equal 'Cancelled', order.reload.shipment_status
    assert_not PurchaseOrder.ready_to_send.exists?(id: order.id)
    assert_equal({ ordered: 1, received: 0, cancelled: 1, outstanding: 0 }, order.stock_receipt_counts.to_h)
  end

  test 'PO date corrections retain receipt boundaries after every stock unit is retired' do
    order = program_stock_order(quantity: 1)
    receive_stock(order, quantity: 1)
    retire_stock(order.equipment_items.sole)

    assert_not order.reload.update(sent_at: Date.current)
    assert_includes order.errors[:sent_at], 'cannot follow a linked shipment or stock receipt'
    assert_not order.reload.update(sent_at: nil)
    assert_includes order.errors[:sent_at], 'cannot be cleared while shipments or stock receipts exist'

    order.reload
    attributes = { 'sent_at' => 3.days.ago.to_date }
    item_versions = order.equipment_items.to_h { |item| [item.id.to_s, item.lock_version.to_s] }
    Equipment::Correction.new(actor: @stock_admin).update_purchase_order!(
      purchase_order: order, attributes:, expected_version: order.lock_version, expected_item_versions: item_versions,
      reason: 'Correct the original actual sent date', confirmed_impact: true,
      impact_token: Equipment::Correction.impact_token(record: order, attributes:, extra: { item_versions: })
    )
    assert_equal 3.days.ago.to_date, order.reload.sent_at
    assert_equal 'Received', order.shipment_status
  end

  private

  def program_stock_order(quantity:)
    @stock_admin = create(:admin)
    product = create(:product)
    group = Equipment::Bidding.new(actor: @stock_admin).create!(number: "STOCK-#{product.id}", purpose: 'program_stock',
                                                                stock: [{ product_id: product.id, quantity: }])
    order = Equipment::Ordering.new(actor: @stock_admin).call(
      bid_group: group, expected_version: group.lock_version, application_versions: {},
      line_versions: group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] },
      purchase_order_attributes: { number: "PO-STOCK-#{product.id}", shipping_address_1: '900 Receiving Road',
                                   shipping_city: 'Baltimore', shipping_state: 'MD', shipping_zip_code: '21201' }
    )
    Equipment::Ordering.new(actor: @stock_admin).mark_sent!(order:, sent_at: 2.days.ago.to_date, expected_version: order.lock_version)
    order
  end

  def receive_stock(order, quantity:)
    Equipment::StockReceipt.new(actor: @stock_admin).receive!(
      order:, received_on: 1.day.ago.to_date, expected_version: order.lock_version,
      rows: [{ batch: order.equipment_items.order(:id).first.stock_receipt_batch, quantity: }],
      item_versions: order.equipment_items.active.where(stock_received_on: nil).to_h { |item| [item.id.to_s, item.lock_version.to_s] }
    )
  end

  def retire_stock(item)
    Equipment::Correction.new(actor: @stock_admin).update_item!(item:, attributes: {}, expected_version: item.lock_version,
                                                                operation: 'withdraw', reason: 'Verified unit cannot be used')
  end
end
