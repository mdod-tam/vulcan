# frozen_string_literal: true

require 'test_helper'

module Equipment
  class OrderingTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @vendor = create(:vendor)
      @writer = Ordering.new(actor: @admin)
      @phone = create(:product, name: 'Phone', device_types: ['Smartphone'])
      @need = create(:equipment_need, product: @phone)
      @attributes = { vendor_id: @vendor.id, number: '00017', sent_at: Date.current }
    end

    test 'mixed models and applications create exactly four independent units on one shared PO' do
      signaler = create(:equipment_need, application: @need.application, product: create(:product, device_types: ['Signaler']))
      two_phones = create(:equipment_need, product: @phone, remaining_quantity: 2)
      assert_difference 'PurchaseOrder.count', 1 do
        assert_difference 'EquipmentItem.count', 4 do
          @order = @writer.call(needs: [row(@need), row(signaler), row(two_phones)], items: [], purchase_order_attributes: @attributes)
        end
      end
      assert_equal [@order.id], EquipmentItem.where(application_id: [@need.application_id, two_phones.application_id]).distinct.pluck(:purchase_order_id)
      assert_equal 2, two_phones.application.equipment_items.where(product: @phone).count
      remaining_quantities = [@need, signaler, two_phones].map { |need| need.reload.remaining_quantity }
      assert_equal [0, 0, 0], remaining_quantities
      assert_equal '00017', @order.number
      assert_nil @need.application.reload.equipment_po_sent_at
      assert_equal 'approved', @need.application.status
    end

    test 'mixed new and detached sources consume one unit and reuse the detached ID' do
      @need.update!(remaining_quantity: 2)
      detached = create(:equipment_item, application: @need.application, product: @phone, purchase_order: nil)
      assert_difference 'EquipmentItem.count', 1 do
        order = @writer.call(needs: [row(@need, 1)], items: [{ id: detached.id, lock_version: detached.lock_version }], purchase_order_attributes: @attributes)
        assert_equal order.id, detached.reload.purchase_order_id
        assert_equal 2, order.equipment_items.count
      end
      assert_equal 1, @need.reload.remaining_quantity
    end

    test 'an invalid row rolls back PO devices quantities and successful audits' do
      other = create(:equipment_need, remaining_quantity: 1)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises Conflict do
          @writer.call(needs: [row(@need), row(other, 2)], items: [], purchase_order_attributes: @attributes)
        end
      end
      assert_equal 1, @need.reload.remaining_quantity
      assert_equal 1, other.reload.remaining_quantity
    end

    test 'repeated submission rejects stale versions without extra units or history' do
      selections = [row(@need)]
      @writer.call(needs: selections, items: [], purchase_order_attributes: @attributes)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises(Conflict) { @writer.call(needs: selections, items: [], purchase_order_attributes: @attributes.merge(number: 'RETRY')) }
      end
    end

    test 'explicit PO reuse creates no header while duplicate normalized vendor numbers require reuse' do
      order = create(:purchase_order, vendor: @vendor, number: ' 00 017 ')
      assert_no_difference 'PurchaseOrder.count' do
        assert_raises ActiveRecord::RecordInvalid do
          @writer.call(needs: [row(@need)], items: [], purchase_order_attributes: @attributes)
        end
        @writer.call(needs: [row(@need)], items: [], purchase_order_id: order.id, expected_po_version: order.lock_version)
      end
      assert_equal order.id, @need.application.equipment_items.sole.purchase_order_id
    end

    test 'one unapproved or unavailable row rejects the entire selection' do
      other = create(:equipment_need)
      other.application.transition_status!(:archived, actor: @admin)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises(Conflict) { @writer.call(needs: [row(@need), row(other)], items: [], purchase_order_attributes: @attributes) }
      end
      @phone.archive!
      assert_raises(Conflict) { @writer.call(needs: [row(@need)], items: [], purchase_order_attributes: @attributes) }
    end

    test 'existing PO membership cannot be overwritten by the bulk writer' do
      item = create(:equipment_item, application: @need.application, product: @phone)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises(Conflict) { @writer.call(needs: [], items: [{ id: item.id, lock_version: item.lock_version }], purchase_order_attributes: @attributes) }
      end
      assert item.reload.purchase_order_id
    end

    test 'legacy facts require explicit mapping without inferred shipments' do
      @need.application.update!(equipment_po_sent_at: 1.day.ago, equipment_tracking_number: 'EARLIER')
      assert_raises(Conflict) { @writer.call(needs: [row(@need)], items: [], purchase_order_attributes: @attributes) }
      order = @writer.call(needs: [row(@need)], items: [], purchase_order_attributes: @attributes, legacy_mapping: true)
      assert_nil order.equipment_items.sole.shipped_at
      assert_nil order.equipment_items.sole.tracking_number
      assert_equal 'EARLIER', @need.application.reload.equipment_tracking_number
    end

    test 'non-administrators cannot place orders' do
      assert_raises(Conflict) { Ordering.new(actor: create(:evaluator)).call(needs: [row(@need)], items: [], purchase_order_attributes: @attributes) }
    end

    private

    def row(need, quantity = need.remaining_quantity)
      { id: need.id, lock_version: need.lock_version, quantity: quantity }
    end
  end
end
