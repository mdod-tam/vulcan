# frozen_string_literal: true

require 'test_helper'

module Equipment
  class AuditCoverageTest < ActiveSupport::TestCase
    include IcanconnectTestSupport

    setup do
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @product = create(:product)
      @application = create(:application, :approved, :with_all_proofs, equipment_needs_initialized_at: Time.current)
      @need = create(:equipment_need, application: @application, product: @product, remaining_quantity: 3, disability_setup_group: 'deaf')
      @bidding = Bidding.new(actor: @admin)
      @ordering = Ordering.new(actor: @admin)
    end

    test 'bid creation quantity changes append and release preserve named before and after values once per operation' do
      group = @bidding.create!(number: 'AUDIT-BID', needs: [need_row(@need, 2)])
      created = group.events.find_by!(action: 'equipment_bid_created')
      assert_actor_and_time(created)
      assert_equal [nil, 'AUDIT-BID'], created.field_change_pairs.fetch('number')
      assert_equal [2], created.field_change_pairs.fetch('bid_lines').last.pluck('quantity')
      line = group.active_lines.sole
      @bidding.change_quantities!(group:, rows: [{ id: line.id, lock_version: line.lock_version, quantity: 1 }],
                                  expected_version: group.lock_version, reason: 'Supplier quoted one device')
      amended = group.events.order(:id).last
      assert_equal 'equipment_bid_amended', amended.action
      assert_equal([[2], [1]], amended.field_change_pairs.fetch('bid_lines').map { |rows| rows.pluck('quantity') })

      other = create(:equipment_need, application: @application, disability_setup_group: 'deaf')
      @bidding.create!(number: '', existing: "#{group.id}:#{group.lock_version}", needs: [need_row(other, 1)])
      appended = group.events.order(:id).last
      assert_equal 'equipment_bid_amended', appended.action
      assert_equal [1, 2], appended.field_change_pairs.fetch('bid_lines').map(&:size)
      @bidding.release!(group:, line_ids: [line.id], expected_version: group.reload.lock_version, reason: 'Use stock for this model')
      released = group.events.order(:id).last
      assert released.field_change_pairs.fetch('bid_lines').last.find { |row| row['id'] == line.id }.fetch('released_at')
      events = [created, amended, appended, released]
      assert_equal events.map(&:id).sort, (application_events & events).map(&:id).sort
      assert_equal events.size, Applications::EventDeduplicationService.new.deduplicate(events).size
      assert_equal events.map(&:id).sort, group.equipment_history.map(&:id).sort
      assert_includes AuditRecords.for(events).fetch(:products), @product
    end

    test 'award PO send supplier costs shipment and corrections reach every affected beneficiary with actor and time' do
      other = create(:equipment_need, product: @product, disability_setup_group: 'deaf')
      group = @bidding.create!(number: 'SHARED-BID', needs: [need_row(@need, 1), need_row(other, 1)])
      prices = group.active_lines.to_h { |line| [line.id.to_s, '45.50'] }
      order = award(group, line_unit_costs: prices, number: 'SHARED-PO', vendor_name: 'Original supplier')
      awarded = order.events.find_by!(action: 'equipment_order_recorded')
      assert_equal [nil, 'SHARED-PO'], awarded.field_change_pairs.fetch('number')
      assert_equal [nil, 'Original supplier'], awarded.field_change_pairs.fetch('vendor_name')
      assert_equal [[], [group.id]], awarded.field_change_pairs.fetch('bid_group_ids')
      assert_equal [BigDecimal('45.50')], awarded.field_change_pairs.fetch('bid_lines').last.pluck('unit_cost').map(&:to_d).uniq
      assert_includes group.equipment_history, awarded
      assert_includes AuditRecords.for([awarded]).fetch(:bid_groups), group

      @ordering.mark_sent!(order:, sent_at: Date.current, expected_version: order.lock_version)
      sent = order.events.find_by!(action: 'equipment_po_sent')
      PurchaseCosts.update!(order:, rows: order.equipment_items.map { |item| { id: item.id, lock_version: item.lock_version, unit_cost: '50' } },
                            expected_version: order.lock_version, actor: @admin, order_attributes: { vendor_name: 'Actual supplier' })
      supplier = order.events.find_by!(action: 'equipment_supplier_recorded')
      [@application, other.application].each do |application|
        logs = application_events(application)
        [awarded, sent, supplier].each do |event|
          assert_includes logs, event
          assert_actor_and_time(event)
        end
      end

      correction = Correction.new(actor: @admin)
      versions = order.equipment_items.to_h { |item| [item.id.to_s, item.lock_version.to_s] }
      header_values = { number: 'CORRECTED-SHARED-PO' }
      header_token = Correction.impact_token(record: order, attributes: header_values, extra: { item_versions: versions })
      correction.update_purchase_order!(purchase_order: order, attributes: header_values, expected_version: order.lock_version,
                                        expected_item_versions: versions, reason: 'Correct the supplier PO reference',
                                        confirmed_impact: true, impact_token: header_token)
      corrected_header = order.events.find_by!(action: 'equipment_purchase_order_corrected')
      assert_equal %w[SHARED-PO CORRECTED-SHARED-PO], corrected_header.field_change_pairs.fetch('number')
      assert_equal [nil, 'SHARED-PO'], awarded.field_change_pairs.fetch('number')
      [@application, other.application].each { |application| assert_includes application_events(application), corrected_header }
      assert_actor_and_time(corrected_header)

      unit = order.equipment_items.find_by!(application: @application)
      Shipment.new(actor: @admin).call(rows: [{ id: unit.id, lock_version: unit.lock_version }],
                                       attributes: { shipped_at: Date.current, tracking_number: 'AUDIT-SHIPMENT', carrier: 'ups' })
      shipment = unit.events.find_by!(action: 'equipment_shipment_recorded')
      assert_equal [nil, 'AUDIT-SHIPMENT'], shipment.field_change_pairs.fetch('tracking_number')
      unit.reload
      values = { tracking_number: 'CORRECTED-SHIPMENT' }
      token = Correction.impact_token(record: unit, attributes: values, extra: { operation: 'update' })
      correction.update_item!(item: unit, attributes: values, expected_version: unit.lock_version, reason: 'Correct courier reference',
                              confirmed_impact: true, impact_token: token)
      changed = unit.events.find_by!(action: 'equipment_item_corrected')
      [shipment, changed].each do |event|
        assert_includes application_events, event
        assert_actor_and_time(event)
      end
      assert_not_includes application_events(other.application), shipment
      assert_includes order.equipment_history, changed
    end

    test 'stock acquisition and the exact received batch follow the allocated unit without unrelated receipt batches' do
      group = @bidding.create!(number: 'STOCK-AUDIT', purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 2 }])
      order = award(group, number: 'STOCK-AUDIT-PO', shipping_address_1: '900 Receiving Road', shipping_city: 'Baltimore',
                           shipping_state: 'MD', shipping_zip_code: '21201')
      @ordering.mark_sent!(order:, sent_at: Date.current, expected_version: order.lock_version)
      receipt = StockReceipt.new(actor: @admin)
      2.times do |index|
        receipt.receive!(order:, received_on: Date.current,
                         rows: [{ batch: order.equipment_items.order(:id).first.stock_receipt_batch, quantity: 1, identifiers: [{ serial_number: "RECEIPT-#{index}" }] }],
                         expected_version: order.lock_version,
                         item_versions: order.equipment_items.where(stock_received_on: nil).to_h { |item| [item.id.to_s, item.lock_version.to_s] })
      end
      first, second = order.equipment_history.where(action: 'equipment_stock_received').reorder(:id).to_a
      allocation = StockAllocation.new(actor: @admin)
      unit = allocation.allocate!(needs: [need_row(@need, 1)], application_versions: equipment_profile_versions(@application)).sole
      logs = application_events

      assert_equal [unit.id], first.metadata.fetch('equipment_item_ids')
      assert_equal [nil, 'RECEIPT-0'], first.field_change_pairs.fetch('serial_number')
      assert_equal({}, first.metadata.dig('changes', 'serial_number'))
      assert_includes logs, first
      assert_not_includes logs, second
      assert_includes logs, group.events.find_by!(action: 'equipment_bid_created')
      assert_includes logs, order.events.find_by!(action: 'equipment_order_recorded')
      assert_includes logs, order.events.find_by!(action: 'equipment_po_sent')
      assert_includes unit.equipment_history, first

      allocation.release!(item: unit, expected_version: unit.lock_version, reason: 'Return to purchasing')
      released = unit.events.find_by!(action: 'equipment_stock_released')
      assert_includes application_events, released
      assert_actor_and_time(released)
    end

    test 'existing stock intake and swaps retain physical identity and history for both units' do
      stock = StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 2, received_on: Date.current,
                                                        provenance: 'Verified shelf inventory', identifiers: [{ serial_number: 'AUDIT-A' }, { serial_number: 'AUDIT-B' }])
      intake = stock.first.events.find_by!(action: 'equipment_existing_stock_recorded')
      assert_equal [nil, 'AUDIT-A'], intake.field_change_pairs.fetch('serial_number')
      assert_equal({}, intake.metadata.dig('changes', 'serial_number'))
      allocation = StockAllocation.new(actor: @admin)
      unit = allocation.allocate!(needs: [need_row(@need, 1)], application_versions: equipment_profile_versions(@application)).sole
      assert_includes application_events, intake
      replacement = stock.find { |item| item.id != unit.id }.reload
      allocation.swap!(item: unit, replacement_id: replacement.id, expected_version: unit.lock_version,
                       replacement_version: replacement.lock_version, reason: 'Use the verified replacement box')
      swapped = replacement.events.find_by!(action: 'equipment_stock_swapped')

      assert_includes unit.equipment_history, swapped
      assert_includes replacement.equipment_history, swapped
      assert_includes application_events, swapped
      assert_actor_and_time(swapped)
    end

    test 'stock allocation and release audit each change to purchasing demand in the application history' do
      StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified shelf inventory')
      allocation = StockAllocation.new(actor: @admin)
      unit = allocation.allocate!(needs: [need_row(@need, 1)], application_versions: equipment_profile_versions(@application)).sole
      allocated = unit.events.find_by!(action: 'equipment_stock_allocated')
      changed = @application.events.where(action: 'equipment_needs_updated').order(:id).last

      assert_equal([3, 2], changed.field_change_pairs.fetch('equipment_needs').map { |rows| rows.sole.fetch('remaining_quantity') })
      assert_equal [@need.id], changed.metadata.fetch('equipment_need_ids')
      assert_equal [unit.id], allocated.metadata.fetch('equipment_item_ids')
      [changed, allocated].each do |event|
        assert_includes application_events, event
        assert_includes unit.equipment_history, event
        assert_actor_and_time(event)
      end

      allocation.release!(item: unit, expected_version: unit.lock_version, reason: 'Return this request to purchasing')
      restored = @application.events.where(action: 'equipment_needs_updated').order(:id).last
      assert_equal([2, 3], restored.field_change_pairs.fetch('equipment_needs').map { |rows| rows.sole.fetch('remaining_quantity') })
      assert_equal 'Return this request to purchasing', restored.metadata['reason']
      assert_includes application_events, restored
      assert_actor_and_time(restored)
    end

    test 'replacing a detached unit swapping its stock and releasing the replacement keep the target history' do
      stock = StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 2, received_on: Date.current,
                                                        provenance: 'Verified replacement devices')
      target = create(:equipment_item, application: @application, product: @product, purchase_order: nil, disability_setup_group: 'deaf')
      allocation = StockAllocation.new(actor: @admin)
      unit = allocation.allocate!(items: [{ id: target.id, lock_version: target.lock_version }],
                                  application_versions: equipment_profile_versions(@application)).sole
      withdrawn = target.events.find_by!(action: 'equipment_replaced_with_stock')
      assert_equal [nil, unit.id], withdrawn.field_change_pairs.fetch('replaced_by_equipment_item_id')
      assert withdrawn.field_change_pairs.fetch('withdrawn_at').last
      assert_includes target.equipment_history, unit.events.find_by!(action: 'equipment_stock_allocated')

      replacement = stock.find { |candidate| candidate.id != unit.id }.reload
      allocation.swap!(item: unit, replacement_id: replacement.id, expected_version: unit.lock_version,
                       replacement_version: replacement.lock_version, reason: 'Use the replacement box')
      swapped = target.events.find_by!(action: 'equipment_replacement_updated')
      assert_equal [unit.id, replacement.id], swapped.field_change_pairs.fetch('replaced_by_equipment_item_id')
      replacement.reload
      allocation.release!(item: replacement, expected_version: replacement.lock_version, reason: 'Restore supplier purchasing')
      restored = target.events.find_by!(action: 'equipment_replacement_released')
      assert_equal [replacement.id, nil], restored.field_change_pairs.fetch('replaced_by_equipment_item_id')
      assert_nil restored.field_change_pairs.fetch('withdrawn_at').last
      [withdrawn, swapped, restored].each do |event|
        assert_includes target.equipment_history, event
        assert_includes application_events, event
        assert_actor_and_time(event)
      end
      assert_nil target.reload.withdrawn_at
    end

    test 'failure to audit the allocated need decrement rolls back demand and physical assignment' do
      unit = StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 1, received_on: Date.current,
                                                       provenance: 'Verified rollback device').sole
      audit = AuditEventService.method(:log)
      fail_need_audit = lambda do |**attributes|
        raise ActiveRecord::RecordInvalid, Event.new if attributes[:action] == 'equipment_needs_updated'

        audit.call(**attributes)
      end
      AuditEventService.stub(:log, fail_need_audit) do
        assert_no_difference 'Event.count' do
          assert_raises(ActiveRecord::RecordInvalid) do
            StockAllocation.new(actor: @admin).allocate!(needs: [need_row(@need, 1)], application_versions: equipment_profile_versions(@application))
          end
        end
      end
      assert_equal 3, @need.reload.remaining_quantity
      assert_nil unit.reload.application_id
    end

    test 'rapid actual financial edits keep separate canonical events in beneficiary and PO history' do
      order = award(@bidding.create!(number: 'COST-BID', needs: [need_row(@need, 1)]), number: 'COST-PO')
      unit = order.equipment_items.sole
      writer = Icanconnect::FilingWriter.new(actor: @admin)
      writer.update_evidence!(record: unit, attributes: { unit_cost: '25' }, lock_version: unit.lock_version)
      writer.update_evidence!(record: unit, attributes: { unit_cost: '30' }, lock_version: unit.lock_version)
      writer.update_evidence!(record: order, attributes: { vendor_name: 'Invoice supplier' }, lock_version: order.reload.lock_version)
      events = Event.where(action: %w[icc_financial_evidence_updated equipment_purchase_cost_recorded], auditable: [unit, order]).order(:id).to_a

      assert_equal 3, events.size
      assert_equal 3, events.map { |event| event.metadata['operation_id'] }.uniq.size
      assert_equal 3, Applications::EventDeduplicationService.new.deduplicate(events).size
      assert_equal events.map(&:id).sort, (application_events & events).map(&:id).sort
      events.each do |event|
        assert_includes order.equipment_history, event
        assert_actor_and_time(event)
      end
    end

    test 'filed equipment marks and audited financial corrections appear in beneficiary history without a second event stream' do
      order, unit = icc_order_with_unit
      writer = Icanconnect::FilingWriter.new(actor: @admin)
      writer.mark!(selections: [filing_selection(unit)], period: 'Audit test period', external_reference: 'AUDIT-FILING')
      writer.correct!(record: unit.reload, attributes: { unit_cost: 149 }, lock_version: unit.lock_version,
                      reason: 'Supplier corrected the equipment charge', external_reference: 'AUDIT-FILING-CORRECTION')
      events = unit.events.where(action: %w[icc_cost_marked_claimed icc_filed_cost_corrected]).order(:id).to_a

      assert_equal 2, events.size
      assert_equal events.map(&:id).sort, (application_events(unit.application) & events).map(&:id).sort
      events.each do |event|
        assert_includes order.equipment_history, event
        assert_actor_and_time(event)
      end
    end

    test 'a failed canonical award audit rolls back its PO units and demand without a success event' do
      group = @bidding.create!(number: 'ROLLBACK-BID', needs: [need_row(@need, 1)])
      AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(Event.new))

      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises(ActiveRecord::RecordInvalid) { award(group, number: 'ROLLBACK-PO') }
      end
      assert group.reload.open?
      assert_equal 3, @need.reload.remaining_quantity
    end

    private

    def need_row(need, quantity)
      { id: need.id, lock_version: need.reload.lock_version, quantity: }
    end

    def award(group, line_unit_costs: {}, **attributes)
      @ordering.call(bid_group: group, expected_version: group.lock_version, application_versions: equipment_bid_profile_versions(group),
                     line_versions: group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] },
                     line_unit_costs:, purchase_order_attributes: attributes)
    end

    def application_events(application = @application)
      Applications::AuditLogBuilder.new(application).build_deduplicated_audit_logs.grep(Event)
    end

    def assert_actor_and_time(event)
      assert_equal @admin.id, event.user_id
      assert event.created_at
      assert event.metadata['operation_id'].present?
    end
  end
end
