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
      assert @item.unfulfilled_since.present?
      assert_equal 0, need.reload.remaining_quantity
      assert_equal 'needs_ordering', @item.queue_status
      assert_equal 'No equipment currently linked', old_order.reload.shipment_status
      group = Bidding.new(actor: @admin).create!(number: 'REBID-DEVICE', items: [{ id: @item.id, lock_version: @item.lock_version }])
      new_order = Ordering.new(actor: @admin).call(bid_group: group, application_versions: equipment_bid_profile_versions(group), expected_version: group.lock_version,
                                                   line_versions: group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] },
                                                   purchase_order_attributes: { number: 'REORDERED' })
      assert_equal old_id, @item.reload.id
      assert_equal new_order.id, @item.purchase_order_id
      assert_equal 0, need.reload.remaining_quantity
    end

    test 'a normal correction cannot assign another PO outside a bid award' do
      original_order_id = @item.purchase_order_id
      another_order = create(:purchase_order)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        error = assert_raises(Conflict) do
          @service.update_item!(item: @item, attributes: { purchase_order_id: another_order.id }, expected_version: 0, reason: 'Move this order')
        end
        assert_includes error.message, 'bid award'
      end
      assert_equal original_order_id, @item.reload.purchase_order_id
      assert_equal 0, @item.lock_version
      assert_equal 'awaiting_shipment', @item.queue_status
    end

    test 'detach and withdrawal reject changed details without changing the device or audit history' do
      replacement = create(:product)
      changes = [
        { product_id: replacement.id.to_s },
        { shipped_at: Date.current.iso8601 }, { shipped_at: '13/45/2026' },
        { tracking_number: 'CorrectedPackage' }, { carrier: 'usps' },
        { serial_number: 'CorrectedSerial' }, { imei: '123456789012345' }
      ]

      %w[detach withdraw].each do |operation|
        if operation == 'withdraw'
          @service.update_item!(item: @item, attributes: {}, expected_version: @item.lock_version,
                                reason: 'Await a replacement order', operation: 'detach')
        end
        original = @item.reload.attributes
        changes.each do |attributes|
          assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
            error = assert_raises(Conflict) do
              @service.update_item!(item: @item, attributes: attributes, expected_version: @item.lock_version,
                                    reason: 'Correct details while changing disposition', operation: operation)
            end
            assert_includes error.message, 'Save device details separately.'
          end
          assert_equal original, @item.reload.attributes
        end
      end
    end

    test 'detach and withdrawal accept unchanged typed and normalized full form values' do
      @item.update!(tracking_number: 'RecordedPackage', serial_number: 'RecordedSerial')
      details = @item.attributes.slice(*Correction::EDITABLE_ITEM_FIELDS).except('purchase_order_id')
      attributes = { product_id: @item.product_id.to_s,
                     shipped_at: '', tracking_number: ' RecordedPackage ', carrier: '', serial_number: ' RecordedSerial ', imei: '' }

      %w[detach withdraw].each do |operation|
        assert_difference 'Event.count', 1 do
          @service.update_item!(item: @item, attributes: attributes, expected_version: @item.lock_version,
                                reason: 'Disposition reviewed', operation: operation)
        end
        assert_equal details, @item.reload.attributes.slice(*details.keys)
        assert_nil @item.purchase_order_id
        expected_fields = operation == 'detach' ? %w[purchase_order_id unfulfilled_since] : ['withdrawn_at']
        assert_equal expected_fields, @item.events.order(:id).last.field_changes.keys
      end
      assert @item.withdrawn_at?
    end

    test 'serial acknowledgment text is encrypted with the device change audit' do
      other_model = create(:product, manufacturer: @item.product.manufacturer, model_number: 'Another model')
      create(:equipment_item, product: other_model, serial_number: 'PRIVATE-SERIAL')
      acknowledgment = 'Reviewed PRIVATE-SERIAL and IMEI 123456789012345; separate manufacturer models.'
      @service.update_item!(item: @item, attributes: { serial_number: 'PRIVATE-SERIAL' }, expected_version: 0,
                            reason: 'Identity reviewed', serial_duplicate_reason: acknowledgment)

      event = @item.events.sole
      assert_nil event.metadata['serial_duplicate_reason']
      assert_equal({}, event.metadata.dig('changes', 'serial_duplicate_reason'))
      assert_equal [nil, acknowledgment], event.field_changes['serial_duplicate_reason']
      raw = Event.connection.select_one("SELECT metadata, change_values FROM events WHERE id = #{event.id}")
      assert(raw.values.none? { |value| value.to_s.include?(acknowledgment) || value.to_s.include?('PRIVATE-SERIAL') || value.to_s.include?('123456789012345') })
    end

    test 'withdrawal keeps the detached device and history but cannot withdraw an ordered device' do
      assert_raises(Conflict) { @service.update_item!(item: @item, attributes: {}, expected_version: 0, reason: 'Not needed', operation: 'withdraw') }
      @service.update_item!(item: @item, attributes: {}, expected_version: 0, reason: 'Wrong order', operation: 'detach')
      @service.update_item!(item: @item, attributes: {}, expected_version: @item.lock_version, reason: 'No longer needed', operation: 'withdraw')
      assert @item.reload.withdrawn_at?
      assert EquipmentItem.exists?(@item.id)
    end

    test 'correction rejects purchase order assignment without creating headers' do
      order = create(:purchase_order, sent_at: nil)
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises(Conflict) do
          @service.update_item!(item: @item, attributes: { purchase_order_id: order.id }, expected_version: @item.lock_version,
                                reason: 'This assignment must go through bid award')
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
      assert_equal 'awaiting_shipment', @item.reload.queue_status
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
      token = Correction.impact_token(record: @item, attributes: attributes, extra: { operation: 'update' })
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
                              reason: 'New assignment')
      end
      assert_raises(Conflict) { Correction.new(actor: create(:evaluator)) }
    end
  end
end
