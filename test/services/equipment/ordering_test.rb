# frozen_string_literal: true

require 'test_helper'

module Equipment
  class OrderingTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @writer = Ordering.new(actor: @admin)
      @phone = create(:product, name: 'Phone', device_types: ['Smartphone'])
      @need = create(:equipment_need, product: @phone)
    end

    test 'a mixed model bid awards exactly four units while preserving application approval' do
      signaler = create(:equipment_need, application: @need.application,
                                         product: create(:product, category: 'alerters_accessories_equipment', device_types: ['Signaler']))
      two_phones = create(:equipment_need, product: @phone, remaining_quantity: 2)
      group = bid(needs: [row(@need), row(signaler), row(two_phones)])
      assert_no_difference 'EquipmentItem.count' do
        assert_equal 4, group.active_lines.sum(:quantity)
      end
      assert_difference 'PurchaseOrder.count', 1 do
        assert_difference 'EquipmentItem.count', 4 do
          @order = award(group)
        end
      end
      assert_nil @order.sent_at
      assert_equal 'PO sent date needed', @order.shipment_status
      assert_equal([0, 0, 0], [@need, signaler, two_phones].map { |need| need.reload.remaining_quantity })
      assert_equal 'approved', @need.application.reload.status
      assert_equal @need.application.shipping_address_1, @order.equipment_items.order(:id).first.shipping_address_1
    end

    test 'mixed need and detached demand consume one quantity and retain the detached physical ID' do
      @need.update!(remaining_quantity: 2)
      detached = create(:equipment_item, application: @need.application, product: @phone, purchase_order: nil)
      group = bid(needs: [row(@need, 1)], items: [{ id: detached.id, lock_version: detached.lock_version }])
      prices = group.active_lines.to_h { |line| [line.id.to_s, line.equipment_item_id ? '0' : '$1,234.50'] }
      assert_difference 'EquipmentItem.count', 1 do
        order = @writer.call(**award_arguments(group), line_unit_costs: prices)
        assert_equal order.id, detached.reload.purchase_order_id
        assert_equal 2, order.equipment_items.count
        assert_equal BigDecimal('0'), detached.unit_cost
        assert_equal BigDecimal('1234.50'), order.equipment_items.where.not(id: detached.id).sole.unit_cost
      end
      assert_equal 1, @need.reload.remaining_quantity
    end

    test 'stock award records the quoted price on every unit and permits an unknown price' do
      group = Bidding.new(actor: @admin).create!(number: 'PRICED-STOCK', purpose: 'program_stock', stock: [
                                                   { product_id: @phone.id, quantity: 2, supplier_setup_group: 'deaf' },
                                                   { product_id: @phone.id, quantity: 1, supplier_setup_group: 'deafblind' }
                                                 ])
      lines = group.active_lines.order(:id).to_a
      arguments = award_arguments(group)
      arguments[:purchase_order_attributes].merge!(vendor_name: ' Stock Supplier ', shipping_address_1: '900 Receiving Road',
                                                   shipping_city: 'Baltimore', shipping_state: 'MD', shipping_zip_code: '21201')
      order = @writer.call(**arguments, line_unit_costs: { lines.first.id.to_s => '49.95', lines.last.id.to_s => '' })
      assert_equal 'Stock Supplier', order.vendor_name
      assert_equal [BigDecimal('49.95'), BigDecimal('49.95')], order.equipment_items.where(acquisition_bid_group_line: lines.first).pluck(:unit_cost)
      assert_nil order.equipment_items.find_by!(acquisition_bid_group_line: lines.last).unit_cost
    end

    test 'invalid or unrelated line prices reject the whole award before creating a PO' do
      group = bid(needs: [row(@need)])
      ['12.345', '-1', 'not a price'].each do |price|
        assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
          assert_raises(Conflict) { @writer.call(**award_arguments(group), line_unit_costs: { group.active_lines.sole.id => price }) }
        end
      end
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises(Conflict) { @writer.call(**award_arguments(group), line_unit_costs: { 'unrelated' => '1' }) }
      end
      assert group.reload.open?
      assert_equal 1, @need.reload.remaining_quantity
    end

    test 'repeated award rejects stale group versions without extra units or successful audits' do
      group = bid(needs: [row(@need)])
      arguments = award_arguments(group)
      @writer.call(**arguments)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises(Conflict) { @writer.call(**arguments) }
      end
    end

    test 'a bid reserves only selected quantity and cannot reserve it twice' do
      group = bid(needs: [row(@need)])
      assert_equal 1, group.active_lines.sum(:quantity)
      assert_equal 0, @need.reload.available_quantity
      assert_no_difference ['BidGroup.count', 'BidGroupLine.count', 'EquipmentItem.count'] do
        assert_raises(Conflict) { bid(needs: [row(@need)]) }
      end
    end

    test 'explicit reuse accepts only an unsent PO of the same purpose and funding' do
      order = create(:purchase_order, sent_at: nil)
      group = bid(needs: [row(@need)])
      assert_no_difference 'PurchaseOrder.count' do
        @writer.call(**award_arguments(group).except(:purchase_order_attributes), existing: "#{order.id}:#{order.lock_version}")
      end
      assert_equal order.id, @need.application.equipment_items.sole.purchase_order_id
      @writer.mark_sent!(order: order.reload, sent_at: Date.current, expected_version: order.lock_version)
      other = create(:equipment_need)
      second = bid(needs: [row(other)])
      assert_raises(Conflict) do
        @writer.call(**award_arguments(second).except(:purchase_order_attributes), existing: "#{order.id}:#{order.lock_version}")
      end
      assert_equal 1, other.reload.remaining_quantity
    end

    test 'program wide normalized PO identity requires explicit reuse' do
      create(:purchase_order, number: ' 00 017 ', sent_at: nil)
      group = bid(needs: [row(@need)])
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count'] do
        assert_raises(ActiveRecord::RecordInvalid) { award(group, number: '00017') }
      end
      assert group.reload.open?
      assert_equal 1, @need.reload.remaining_quantity
    end

    test 'award rechecks current availability setup and application authority atomically' do
      group = bid(needs: [row(@need)])
      @phone.archive!
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count'] do
        assert_raises(Conflict) { award(group) }
      end
      assert_equal 1, @need.reload.remaining_quantity
      @phone.unarchive!
      @need.application.update!(shipping_address_1: nil)
      assert_raises(Conflict) { award(group) }
      @need.application.transition_status!(:archived, actor: @admin)
      assert_raises(Conflict) { award(group) }
    end

    test 'direct shipments require a separately recorded sent date and empty orders cannot be sent' do
      order = award(bid(needs: [row(@need)]))
      item = order.equipment_items.sole
      assert_not item.update(shipped_at: Date.current, tracking_number: 'TRACK')
      @writer.mark_sent!(order: order, sent_at: Date.current, expected_version: order.lock_version)
      assert item.reload.update(shipped_at: Date.current, tracking_number: 'TRACK')
      empty = create(:purchase_order, sent_at: nil)
      assert_raises(ActiveRecord::RecordInvalid) do
        @writer.mark_sent!(order: empty, sent_at: Date.current, expected_version: empty.lock_version)
      end
    end

    test 'non administrators cannot create bids or awards' do
      actor = create(:evaluator)
      assert_raises(Conflict) { Ordering.new(actor: actor) }
      assert_raises(Conflict) { Bidding.new(actor: actor) }
    end

    private

    def row(need, quantity = need.remaining_quantity)
      { id: need.id, lock_version: need.lock_version, quantity: quantity }
    end

    def bid(**selections)
      Bidding.new(actor: @admin).create!(number: "BID-#{SecureRandom.hex(4)}", **selections)
    end

    def award_arguments(group)
      { bid_group: group, application_versions: equipment_bid_profile_versions(group), expected_version: group.lock_version,
        line_versions: group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] },
        purchase_order_attributes: { number: "PO-#{SecureRandom.hex(4)}" } }
    end

    def award(group, number: nil)
      arguments = award_arguments(group)
      arguments[:purchase_order_attributes][:number] = number if number
      @writer.call(**arguments)
    end
  end
end
