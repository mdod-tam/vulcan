# frozen_string_literal: true

require 'test_helper'

module Equipment
  class CorrectionTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @item = create(:equipment_item)
      @service = Correction.new(actor: @admin)
    end

    test 'detach retains the physical identity and does not regenerate remaining needs' do
      need = EquipmentNeed.create!(application: @item.application, product: @item.product, remaining_quantity: 0)
      old_id = @item.id
      old_order = @item.purchase_order
      @service.update_item!(item: @item, attributes: {}, expected_version: @item.lock_version, reason: 'Ordered accidentally', operation: 'detach')
      assert_nil @item.reload.purchase_order_id
      assert_equal 0, need.reload.remaining_quantity
      assert_equal 'needs_ordering', @item.queue_status
      assert_equal 'No equipment currently linked', old_order.reload.shipment_status
      new_order = create(:purchase_order)
      @service.update_item!(item: @item, attributes: { purchase_order_id: new_order.id }, expected_version: @item.lock_version,
                            purchase_order_versions: { new_order.id => new_order.lock_version }, reason: 'Reordered with correct vendor')
      assert_equal old_id, @item.reload.id
      assert_equal new_order.id, @item.purchase_order_id
      assert_equal 0, need.reload.remaining_quantity
      assert_equal 2, @item.events.count
    end

    test 'withdrawal keeps the detached device and history but cannot withdraw an ordered device' do
      assert_raises(Conflict) { @service.update_item!(item: @item, attributes: {}, expected_version: 0, reason: 'Not needed', operation: 'withdraw') }
      @service.update_item!(item: @item, attributes: {}, expected_version: 0, reason: 'Wrong order', operation: 'detach')
      @service.update_item!(item: @item, attributes: {}, expected_version: @item.lock_version, reason: 'No longer needed', operation: 'withdraw')
      assert @item.reload.withdrawn_at?
      assert EquipmentItem.exists?(@item.id)
    end

    test 'moving to a new header preserves the item and sibling and stale or invalid retries roll back the header' do
      old_order = @item.purchase_order
      sibling = create(:equipment_item, application: @item.application, product: @item.product, purchase_order: old_order)
      new_order = { vendor_id: old_order.vendor_id, number: 'Corrected Header', sent_at: old_order.sent_at.iso8601 }
      assert_difference 'PurchaseOrder.count', 1 do
        assert_no_difference 'EquipmentItem.count' do
          @service.update_item!(item: @item, attributes: {}, expected_version: 0, new_purchase_order: new_order, reason: 'One device belongs to another order')
        end
      end
      assert_equal old_order.id, sibling.reload.purchase_order_id
      assert_not_equal old_order.id, @item.reload.purchase_order_id
      assert_no_difference ['PurchaseOrder.count', 'Event.count'] do
        assert_raises(Conflict) do
          @service.update_item!(item: @item, attributes: {}, expected_version: 0, new_purchase_order: new_order, reason: 'Repeated old browser submission')
        end
        assert_raises(ActiveRecord::RecordInvalid) do
          @service.update_item!(item: @item, attributes: { shipped_at: Date.current + 1.day, tracking_number: 'Package' },
                                expected_version: @item.lock_version, new_purchase_order: new_order.merge(number: 'Invalid Header'), reason: 'Invalid future shipment')
        end
      end
    end

    test 'stale and repeated submissions have no successful changes or audits' do
      @service.update_item!(item: @item, attributes: { tracking_number: 'FirstPackage' }, expected_version: 0, reason: 'Tracking supplied')
      assert_no_difference 'Event.count' do
        assert_raises(Conflict) { @service.update_item!(item: @item, attributes: { tracking_number: 'SecondPackage' }, expected_version: 0, reason: 'Retry') }
      end
      assert_equal 'FirstPackage', @item.reload.tracking_number
    end

    test 'tracking saves and rapid corrections keep distinct encrypted old and new history' do
      @service.update_item!(item: @item, attributes: { tracking_number: 'FirstPackage', imei: '123456789012345' }, expected_version: 0, reason: 'Device identified')
      @service.update_item!(item: @item, attributes: { tracking_number: 'SecondPackage' }, expected_version: @item.lock_version, reason: 'Tracking corrected')
      assert_equal 'ordered', @item.reload.queue_status
      events = @item.events.order(:id).to_a
      assert_equal 2, events.size
      assert_equal({}, events.last.metadata.dig('changes', 'tracking_number'))
      assert_equal({ 'old' => 'FirstPackage', 'new' => 'SecondPackage' }, events.last.field_changes['tracking_number'])
      assert_equal 2, Applications::EventDeduplicationService.new.deduplicate(events).size
      assert_equal events.map(&:id).sort, (Applications::AuditLogBuilder.new(@item.application).build_audit_logs & events).map(&:id).sort
    end

    test 'shipped product and PO corrections require reviewed values and preserve shipment facts' do
      @item.update!(shipped_at: Date.current, tracking_number: 'Package')
      replacement = create(:product)
      attributes = { 'product_id' => replacement.id.to_s }
      assert_raises(Conflict) { @service.update_item!(item: @item, attributes: attributes, expected_version: @item.lock_version, reason: 'Wrong catalog product', confirmed_impact: true) }
      token = Correction.impact_token(record: @item, attributes: attributes, extra: { operation: 'update', new_purchase_order: {} })
      @service.update_item!(item: @item, attributes: attributes, expected_version: @item.lock_version,
                            reason: 'Wrong catalog product', confirmed_impact: true, impact_token: token)
      assert_equal replacement, @item.reload.product
      assert_equal Date.current, @item.shipped_at
      assert_equal 'Package', @item.tracking_number
      assert_raises(Conflict) { @service.update_item!(item: @item, attributes: {}, expected_version: @item.lock_version, reason: 'Detach', operation: 'detach') }
    end

    test 'shared header confirmation is tied to the reviewed membership and values' do
      order = @item.purchase_order
      sibling = create(:equipment_item, purchase_order: order)
      versions = { @item.id.to_s => @item.lock_version.to_s, sibling.id.to_s => sibling.lock_version.to_s }
      attributes = { 'number' => 'Corrected PO' }
      token = Correction.impact_token(record: order, attributes: attributes, extra: { item_versions: versions })
      assert_raises(Conflict) do
        @service.update_purchase_order!(purchase_order: order, attributes: { 'number' => 'Another number' }, expected_version: order.lock_version,
                                        expected_item_versions: versions, reason: 'Wrong number', confirmed_impact: true, impact_token: token)
      end
      @service.update_purchase_order!(purchase_order: order, attributes: attributes, expected_version: order.lock_version,
                                      expected_item_versions: versions, reason: 'Wrong number', confirmed_impact: true, impact_token: token)
      assert_equal 'Corrected PO', sibling.reload.purchase_order.number
      create(:equipment_item, purchase_order: order)
      assert_raises(Conflict) do
        @service.update_purchase_order!(purchase_order: order, attributes: attributes, expected_version: order.lock_version,
                                        expected_item_versions: versions, reason: 'Stale membership', confirmed_impact: true, impact_token: token)
      end
    end

    test 'header dates cannot bypass linked shipment validation and failure is atomic' do
      @item.update!(shipped_at: Date.current - 1.day, tracking_number: 'Package')
      order = @item.purchase_order
      versions = { @item.id.to_s => @item.lock_version.to_s }
      attributes = { 'sent_at' => Date.current.iso8601 }
      token = Correction.impact_token(record: order, attributes: attributes, extra: { item_versions: versions })
      assert_no_difference 'Event.count' do
        assert_raises(ActiveRecord::RecordInvalid) do
          @service.update_purchase_order!(purchase_order: order, attributes: attributes, expected_version: order.lock_version,
                                          expected_item_versions: versions, reason: 'Date correction', confirmed_impact: true, impact_token: token)
        end
      end
      assert_equal Date.current - 2.days, order.reload.sent_at
    end

    test 'historical shipment corrections are allowed but new assignments require approval' do
      application = create(:application, :completed, :with_all_proofs, status: :rejected, fulfillment_type: :equipment)
      item = create(:equipment_item, application: application)
      @service.update_item!(item: item, attributes: { shipped_at: Date.current, tracking_number: 'HistoricalPackage' }, expected_version: 0, reason: 'Record actual shipment')
      assert_equal 'shipped', item.reload.queue_status
      detached = create(:equipment_item, application: application, purchase_order: nil)
      order = create(:purchase_order)
      assert_raises(Conflict) do
        @service.update_item!(item: detached, attributes: { purchase_order_id: order.id }, expected_version: 0,
                              purchase_order_versions: { order.id => order.lock_version }, reason: 'New assignment')
      end
      assert_raises(Conflict) { Correction.new(actor: create(:evaluator)) }
    end
  end
end
