# frozen_string_literal: true

require 'test_helper'

module Equipment
  class SupplierListTest < ActiveSupport::TestCase
    setup do
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @product = create(:product)
      @bidding = Bidding.new(actor: @admin)
      @ordering = Ordering.new(actor: @admin)
    end

    test 'an unsent full PO list includes complete current destinations across reused bids without private device data' do
      @product.update!(manufacturer: 'Example Maker', name: 'Example Maker Model Pro XL', model_number: 'Model Pro XL')
      first = equipment_application('Same', 'Name', '101 Main Street', 'Unit A')
      second = equipment_application('Same', 'Name', '202 Main Street', 'Unit B')
      first_need = create(:equipment_need, application: first, product: @product, remaining_quantity: 2, disability_setup_group: 'deaf')
      second_need = create(:equipment_need, application: second, product: @product, disability_setup_group: 'deaf')
      first_bid = bid('FIRST-BID', first_need, 2)
      order = award(first_bid, number: 'SUPPLIER-PO')
      second_bid = bid('SECOND-BID', second_need, 1)
      @ordering.call(bid_group: second_bid, application_versions: equipment_bid_profile_versions(second_bid), expected_version: second_bid.lock_version, line_versions: versions(second_bid),
                     existing: "#{order.id}:#{order.lock_version}")
      unit = order.equipment_items.order(:id).first
      unit.update!(serial_number: 'PRIVATE-DEVICE-SERIAL', imei: '123456789012345')

      list = SupplierList.new(purchase_order: order)
      assert_equal ['Example Maker · Model Pro XL'], list.rows.map(&:model).uniq
      assert_nil order.reload.sent_at
      assert_equal [1, 2], list.rows.map(&:quantity).sort
      assert_equal 3, list.rows.sum(&:quantity)
      assert_equal ['Product model', 'Quantity', 'Recipient', 'Shipping address'], list.headings
      assert_includes list.plain_text, 'PO SUPPLIER-PO'
      assert_not_includes list.plain_text, 'Disability setup'
      assert_not_includes list.plain_text, 'Deaf'
      assert_includes list.plain_text, '101 Main Street'
      assert_includes list.plain_text, 'Unit A'
      assert_includes list.plain_text, 'Care of Guardian'
      assert_includes list.plain_text, '202 Main Street'
      assert_not_includes list.plain_text, unit.serial_number
      assert_not_includes list.plain_text, unit.imei

      # Current PO membership, rather than historical bid lines, owns the copy.
      unit.update!(purchase_order: nil)
      assert_equal 2, SupplierList.new(purchase_order: order).rows.sum(&:quantity)
    end

    test 'supplier copy uses the stock receiving address and omits internal setup and onward dispatch' do
      group = @bidding.create!(number: 'STOCK-ORIGINAL', purpose: 'program_stock', stock: [
                                 { product_id: @product.id, quantity: 1, supplier_setup_group: nil },
                                 { product_id: @product.id, quantity: 1, supplier_setup_group: 'deafblind' }
                               ])
      order = award(group, number: 'STOCK-SUPPLIER', shipping_address_1: '900 Receiving Road', shipping_address_2: 'Dock 3',
                           shipping_city: 'Baltimore', shipping_state: 'MD', shipping_zip_code: '21201')
      unreceived = SupplierList.new(purchase_order: order)
      assert_equal 'Shipping address', unreceived.headings.last
      assert_equal 2, unreceived.rows.sole.quantity
      @ordering.mark_sent!(order:, sent_at: Date.current, expected_version: order.lock_version)
      rows = order.equipment_items.map { |item| { batch: item.stock_receipt_batch, quantity: 1 } }
      StockReceipt.new(actor: @admin).receive!(order:, received_on: Date.current, rows: rows,
                                               expected_version: order.lock_version,
                                               item_versions: order.equipment_items.to_h { |item| [item.id.to_s, item.lock_version.to_s] })
      application = equipment_application('Beneficiary', 'One', '777 Constituent Street', 'Unit Z')
      need = create(:equipment_need, application:, product: @product, disability_setup_group: 'deaf')
      unit = StockAllocation.new(actor: @admin).allocate!(needs: [{ id: need.id, lock_version: need.lock_version, quantity: 1 }], application_versions: equipment_profile_versions(need.application)).sole

      list = SupplierList.new(purchase_order: order)
      assert_equal 2, list.rows.sole.quantity
      assert_nil list.rows.sole.setup
      assert(list.rows.all? { |row| row.recipient == 'Program stock' })
      assert_includes list.plain_text, '900 Receiving Road'
      assert_includes list.plain_text, 'Dock 3'
      assert_not_includes list.plain_text, '777 Constituent Street'
      assert_not_includes list.plain_text, application.user.full_name
      assert_not_includes list.plain_text, 'DeafBlind'
      assert_includes list.plain_text, "\t2\tProgram stock\t"
      assert_equal 'deaf', unit.disability_setup_group
      replacement = order.equipment_items.available_stock.sole
      StockAllocation.new(actor: @admin).swap!(item: unit, replacement_id: replacement.id, expected_version: unit.lock_version,
                                               replacement_version: replacement.lock_version, reason: 'Verified another exact-model box')
      assert_equal list.plain_text, SupplierList.new(purchase_order: order).plain_text
      dispatch = SupplierList.new(dispatch_items: [replacement.reload])
      assert_equal 'Deaf', dispatch.rows.sole.setup
      assert_equal application.user.full_name, dispatch.rows.sole.recipient
      assert_includes dispatch.plain_text, '777 Constituent Street'
      assert_not_includes dispatch.plain_text, '900 Receiving Road'
      StockAllocation.new(actor: @admin).release!(item: replacement, expected_version: replacement.lock_version, reason: 'Restore request')
      assert_equal list.plain_text, SupplierList.new(purchase_order: order).plain_text
      allocated = StockAllocation.new(actor: @admin).allocate!(needs: [{ id: need.id, lock_version: need.reload.lock_version, quantity: 1 }],
                                                               application_versions: equipment_profile_versions(need.application)).sole
      supplier_copy = SupplierList.new(purchase_order: order).plain_text
      Shipment.new(actor: @admin).call(rows: [{ id: allocated.id.to_s, lock_version: allocated.lock_version.to_s }],
                                       attributes: { shipped_at: Date.current, tracking_number: 'ACTUAL-OUTBOUND' }, confirm_setup: true)
      assert_equal supplier_copy, SupplierList.new(purchase_order: order).plain_text
      dispatched = SupplierList.new(dispatch_items: [allocated.reload])
      assert_equal 'Already shipped', dispatched.table_values(dispatched.rows.sole).last
    end

    private

    def equipment_application(first_name, last_name, street, apartment)
      create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment,
                                                        user: create(:constituent, first_name:, last_name:), program_disability_groups: ['deaf'],
                                                        shipping_care_of: 'Guardian', shipping_address_1: street, shipping_address_2: apartment,
                                                        shipping_city: 'Baltimore', shipping_state: 'MD', shipping_zip_code: '21201')
    end

    def bid(number, need, quantity)
      @bidding.create!(number:, needs: [{ id: need.id, quantity:, lock_version: need.lock_version }])
    end

    def versions(group)
      group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] }
    end

    def award(group, **attributes)
      @ordering.call(bid_group: group, application_versions: equipment_bid_profile_versions(group), expected_version: group.lock_version, line_versions: versions(group), purchase_order_attributes: attributes)
    end
  end
end
