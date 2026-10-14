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
        order = @writer.call(needs: [row(@need, 1).merge(id: @need.id.to_s)],
                             items: [{ id: detached.id.to_s, lock_version: detached.lock_version }], purchase_order_attributes: @attributes)
        assert_equal order.id, detached.reload.purchase_order_id
        assert_equal 2, order.equipment_items.count
        event = Event.find_by!(auditable: order, action: 'equipment_order_recorded')
        assert_equal [order.equipment_items.where.not(id: detached.id).sole.id, detached.id], event.metadata['equipment_item_ids']
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
        error = assert_raises ActiveRecord::RecordInvalid do
          @writer.call(needs: [row(@need)], items: [], purchase_order_attributes: @attributes)
        end
        assert_includes error.record.errors.full_messages.join, 'PO number is already recorded for this vendor; choose the existing purchase order'
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

    test 'a saved legacy purchasing decision retains deliberate mapping on a later order' do
      application = create(:application, :approved, :with_all_proofs, equipment_po_sent_at: 1.day.ago)
      EquipmentNeeds::Writer.update!(application, rows: [], expected_initialized_at: '', actor: @admin, reason: 'Delivered before this system')
      assert_not application.reload.equipment_legacy_review?
      assert application.equipment_legacy_unmapped?
      EquipmentNeeds::Writer.update!(application,
                                     rows: [{ product_id: @phone.id, remaining_quantity: 1 }],
                                     expected_initialized_at: application.equipment_needs_initialized_at.iso8601(6),
                                     actor: @admin, reason: 'A new catalog device is now required')
      need = application.equipment_needs.sole
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises(Conflict) { @writer.call(needs: [row(need)], items: [], purchase_order_attributes: @attributes) }
      end
      order = @writer.call(needs: [row(need)], items: [], purchase_order_attributes: @attributes, legacy_mapping: true)
      assert_equal order.id, application.equipment_items.sole.purchase_order_id
      assert_equal :po_sent, application.reload.admin_fulfillment_responsibility_state
    end

    test 'new purchase orders use the existing vendor eligibility rule including legacy active status' do
      vendor = create(:vendor, status: nil)
      order = @writer.call(needs: [row(@need)], items: [], purchase_order_attributes: @attributes.merge(vendor_id: vendor.id))
      assert_equal vendor.id, order.vendor_id
      assert_equal 0, @need.reload.remaining_quantity

      another_need = create(:equipment_need)
      vendor.update!(status: :suspended)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        error = assert_raises(ActiveRecord::RecordInvalid) do
          @writer.call(needs: [row(another_need)], items: [], purchase_order_attributes: @attributes.merge(vendor_id: vendor.id, number: 'INACTIVE-RETRY'))
        end
        assert_includes error.record.errors[:vendor].join, 'active vendor'
      end
      assert_equal 1, another_need.reload.remaining_quantity
    end

    private

    def row(need, quantity = need.remaining_quantity)
      { id: need.id, lock_version: need.lock_version, quantity: quantity }
    end
  end
end
