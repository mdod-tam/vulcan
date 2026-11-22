# frozen_string_literal: true

require 'test_helper'

module Equipment
  class MvpFlowTest < ActiveSupport::TestCase
    include IcanconnectTestSupport

    setup do
      start_icanconnect!
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @bidding = Bidding.new(actor: @admin)
      @ordering = Ordering.new(actor: @admin)
      @receipt = StockReceipt.new(actor: @admin)
      @allocation = StockAllocation.new(actor: @admin)
      @product = create(:product)
    end

    test 'iCanConnect launch controls bid reservations and awards while preserving the reviewed requests' do
      application = approved_deafblind_application
      application.update!(shipping)
      need = create(:equipment_need, application:, disability_setup_group: 'deafblind')
      start_icanconnect!(on: Date.tomorrow)
      assert_no_difference('BidGroup.count') do
        error = assert_raises(Conflict) do
          @bidding.create!(number: 'ICC-SCHEDULED', funding_source: 'icanconnect', needs: [need_row(need, 1)])
        end
        assert_includes error.message, 'start date in System Policies'
      end
      assert_equal 1, need.reload.available_quantity

      start_icanconnect!(on: Date.current)
      bid = @bidding.create!(number: 'ICC-ACTIVE', funding_source: 'icanconnect', needs: [need_row(need, 1)])
      start_icanconnect!(on: nil)
      assert_no_difference('PurchaseOrder.count') do
        error = assert_raises(Conflict) { award(bid, number: 'ICC-PAUSED') }
        assert_includes error.message, 'start date in System Policies'
      end
      assert bid.reload.open?
      assert_equal 0, need.reload.available_quantity
    end

    test 'a mixed model bid reserves once then records an unsent PO before actual sending and shipment' do
      application = application_for_equipment
      first = create(:equipment_need, application:, product: @product, remaining_quantity: 2, disability_setup_group: 'deaf')
      second = create(:equipment_need, application:, disability_setup_group: 'deaf')
      group = @bidding.create!(number: 'Mixed models', needs: [need_row(first, 1), need_row(second, 1)])
      assert_equal 1, first.reload.available_quantity
      assert_equal 0, second.reload.available_quantity
      assert_no_difference('EquipmentItem.count') do
        assert_raises(Conflict) { @bidding.create!(number: 'Duplicate reservation', needs: [need_row(second, 1)]) }
      end

      order = award(group, number: 'PO-MIXED')
      assert_nil order.sent_at
      assert_equal 2, order.equipment_items.count
      assert_equal 1, first.reload.remaining_quantity
      assert_equal 0, second.reload.remaining_quantity
      unit = order.equipment_items.order(:id).first
      assert_equal application.shipping_snapshot, unit.shipping_snapshot
      assert_raises(ActiveRecord::RecordInvalid) { unit.update!(shipped_at: Date.current, tracking_number: 'BEFORE-SENT') }
      unit.reload
      @ordering.mark_sent!(order:, sent_at: Date.current, expected_version: order.lock_version)
      unit.update!(shipped_at: Date.current, tracking_number: 'ACTUAL-SHIPMENT')
      assert_equal 'shipped', unit.queue_status
      assert_equal :needs_fulfillment, application.reload.equipment_fulfillment_stage.stage
      assert_equal({ awaiting_shipment: 1, awaiting_delivery: 1 }, application.equipment_fulfillment_stage.secondary.to_h { |work| [work.stage, work.quantity] })
    end

    test 'releasing unquoted lines before award leaves the remainder unreserved and preserves bid history' do
      need = create(:equipment_need, application: application_for_equipment, product: @product, remaining_quantity: 3, disability_setup_group: 'deaf')
      group = @bidding.create!(number: 'BID-PARTIAL', needs: [need_row(need, 2)])
      line = group.active_lines.sole
      @bidding.release!(group:, line_ids: [line.id], expected_version: group.lock_version, reason: 'Supplier did not quote this line')
      assert_equal 3, need.reload.available_quantity
      assert group.reload.open?
      assert line.reload.released_at
      assert_not BidGroup.awaiting_award.exists?(group.id)
      assert_no_difference('PurchaseOrder.count') { assert_raises(Conflict) { award(group, number: 'EMPTY-BID') } }
      @bidding.create!(number: '', needs: [need_row(need, 1)], existing: "#{group.id}:#{group.lock_version}")
      assert BidGroup.awaiting_award.exists?(group.id)
      assert_equal 'BID-PARTIAL', group.reload.number
      @bidding.release!(group: group, line_ids: group.active_lines.ids, expected_version: group.lock_version, reason: 'Waiting for the corrected quote')
      @bidding.release!(group: group.reload, line_ids: [], expected_version: group.lock_version, reason: 'The bid is no longer needed', cancel: true)
      assert group.reload.cancelled_at
      assert_equal group.cancelled_at.to_i, Time.iso8601(group.events.order(:id).last.field_change_pairs['cancelled_at'].last).to_i
      assert_no_difference('BidGroupLine.count') do
        assert_raises(Conflict) { @bidding.create!(number: '', needs: [need_row(need, 1)], existing: "#{group.id}:#{group.lock_version}") }
      end
    end

    test 'reserved needs can confirm setup and change demand without losing their bid' do
      application = application_for_equipment
      need = create(:equipment_need, application:, product: @product, remaining_quantity: 2, disability_setup_group: nil)
      group = @bidding.create!(number: 'SETUP-TO-CONFIRM', needs: [need_row(need, 2)])
      line = group.active_lines.sole
      reviewed_version = group.lock_version
      assert_no_difference('PurchaseOrder.count') { assert_raises(Conflict) { award(group, number: 'MISSING-SETUP') } }
      row = need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version', 'disability_setup_group')
                .merge('remaining_quantity' => 3, 'disability_setup_group' => 'deaf')
      EquipmentNeeds::Writer.update!(application, rows: [row], expected_initialized_at: application.equipment_needs_initialized_at.iso8601(6),
                                                  actor: @admin, reason: 'Confirmed setup and one additional device')
      assert_equal 3, need.reload.remaining_quantity
      assert_equal 2, need.reserved_quantity
      assert_equal 'deaf', need.disability_setup_group
      assert group.reload.open?
      assert_equal line.id, group.active_lines.sole.id
      assert_not_equal reviewed_version, group.lock_version
      assert group.membership_changed_at
      assert_raises(Conflict) do
        @ordering.call(bid_group: group, expected_version: reviewed_version, line_versions: line_versions(group),
                       application_versions: equipment_bid_profile_versions(group), purchase_order_attributes: { number: 'STALE-SETUP' })
      end
      [{ 'remaining_quantity' => 1 }, { 'remaining_quantity' => 0 }, { 'disability_setup_group' => 'speech' }, { 'product_id' => create(:product).id }].each do |invalid|
        submitted = need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version', 'disability_setup_group').merge(invalid)
        assert_no_difference('Event.count') do
          assert_raises(Conflict) do
            EquipmentNeeds::Writer.update!(application, rows: [submitted], expected_initialized_at: application.equipment_needs_initialized_at.iso8601(6),
                                                        actor: @admin, reason: 'Attempt to remove reserved demand')
          end
        end
      end
      submitted = need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version', 'disability_setup_group').merge('remaining_quantity' => 2)
      EquipmentNeeds::Writer.update!(application, rows: [submitted], expected_initialized_at: application.equipment_needs_initialized_at.iso8601(6),
                                                  actor: @admin, reason: 'Only the reserved quantity is needed')
      order = award(group.reload, number: 'SETUP-CONFIRMED')
      assert_equal 2, order.equipment_items.count
      assert_equal ['deaf'], order.equipment_items.distinct.pluck(:disability_setup_group)
      assert_equal 0, need.reload.remaining_quantity
      assert_equal 'Confirmed setup and one additional device', application.events.find_by!(action: 'equipment_needs_updated').metadata['reason']
    end

    test 'bid quantity amendment and explicit append retain one reviewed mixed-model reservation set' do
      application = application_for_equipment
      first = create(:equipment_need, application:, product: @product, remaining_quantity: 3, disability_setup_group: 'deaf')
      second = create(:equipment_need, application:, disability_setup_group: 'deaf')
      third = create(:equipment_need, application:, disability_setup_group: 'deaf')
      group = @bidding.create!(number: 'AMENDED-BID', needs: [need_row(first, 3)])
      original_line = group.active_lines.sole
      @bidding.change_quantities!(group:, rows: [{ id: original_line.id, quantity: 1, lock_version: original_line.lock_version }],
                                  expected_version: group.lock_version, reason: 'Only one unit was quoted')
      assert_equal 2, first.reload.available_quantity
      assert_equal 1, original_line.reload.quantity
      stale = "#{group.id}:#{group.lock_version}"
      @bidding.create!(number: '', needs: [need_row(second, 1)], existing: stale)
      assert_equal 2, group.reload.active_lines.count
      assert group.membership_changed_at
      assert_equal 0, second.reload.available_quantity
      assert_no_difference('BidGroupLine.count') do
        assert_raises(Conflict) { @bidding.create!(number: '', needs: [need_row(third, 1)], existing: stale) }
      end
      assert_equal 1, third.reload.available_quantity
      assert_equal 1, BidGroup.where(number: 'AMENDED-BID').count
    end

    test 'stock PO partial receipt rejects stale balances and never becomes constituent shipment' do
      group = @bidding.create!(number: 'STOCK-BUY', purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 3, supplier_setup_group: 'deaf' }])
      order = award(group, number: 'PO-STOCK', **shipping)
      assert_equal 0, order.equipment_items.distinct.count(:application_id)
      line = group.active_lines.sole
      assert_not line.update(supplier_setup_group: 'mobility')
      assert_equal 'deaf', line.reload.supplier_setup_group
      assert_no_difference('EquipmentItem.available_stock.count') do
        assert_raises(Conflict) { receive(order, quantity: 1) }
      end
      @ordering.mark_sent!(order:, sent_at: Date.current, expected_version: order.lock_version)
      versions = outstanding_versions(order)
      @receipt.receive!(order:, received_on: Date.current, rows: [{ batch: order.equipment_items.order(:id).first.stock_receipt_batch, quantity: 1 }], expected_version: order.lock_version, item_versions: versions)
      assert_equal 1, order.equipment_items.where.not(stock_received_on: nil).count
      assert_equal 2, EquipmentItem.incoming_stock.where(purchase_order: order).count
      assert_equal 1, EquipmentItem.available_stock.where(purchase_order: order).count
      assert_empty order.equipment_items.where.not(shipped_at: nil)
      assert_raises(Conflict) do
        @receipt.receive!(order:, received_on: Date.current, rows: [{ batch: order.equipment_items.order(:id).first.stock_receipt_batch, quantity: 1 }], expected_version: order.lock_version, item_versions: versions)
      end
      assert_equal 1, order.equipment_items.where.not(stock_received_on: nil).count
      receive(order, quantity: 2)
      assert_empty EquipmentItem.incoming_stock.where(purchase_order: order)
      assert_equal 3, EquipmentItem.available_stock.where(purchase_order: order).count
    end

    test 'receipt rejects repeated order line rows instead of receiving one physical unit twice' do
      group = @bidding.create!(number: 'STOCK-DUPLICATE-ROWS', purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 1 }])
      order = award(group, number: 'PO-DUPLICATE-ROWS', **shipping)
      @ordering.mark_sent!(order:, sent_at: Date.current, expected_version: order.lock_version)
      assert_raises(Conflict) do
        @receipt.receive!(order:, received_on: Date.current,
                          rows: 2.times.map { { batch: order.equipment_items.order(:id).first.stock_receipt_batch, quantity: 1 } },
                          expected_version: order.lock_version, item_versions: outstanding_versions(order))
      end
      assert_empty order.equipment_items.where.not(stock_received_on: nil)
    end

    test 'stock receipt preserves recorded identifiers when the fields are blank and rejects replacement' do
      group = @bidding.create!(number: 'STOCK-IDENTIFIERS', purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 1 }])
      order = award(group, number: 'PO-IDENTIFIERS', **shipping)
      @ordering.mark_sent!(order:, sent_at: Date.current, expected_version: order.lock_version)
      unit = order.equipment_items.sole
      Correction.new(actor: @admin).update_item!(item: unit, attributes: { serial_number: 'KNOWN-SERIAL', imei: '123456789012345' },
                                                 expected_version: unit.lock_version, reason: 'Identifiers provided by vendor')
      receipt = {
        order:, received_on: Date.current, expected_version: order.lock_version, item_versions: outstanding_versions(order)
      }
      row = { batch: unit.stock_receipt_batch, quantity: 1 }

      assert_no_difference "Event.where(action: 'equipment_stock_received').count" do
        assert_raises(Conflict) { @receipt.receive!(**receipt, rows: [row.merge(identifiers: [{ serial_number: 'REPLACEMENT' }])]) }
      end
      assert_nil unit.reload.stock_received_on

      @receipt.receive!(**receipt, rows: [row.merge(identifiers: [{ serial_number: '', imei: '' }])])

      assert_equal Date.current, unit.reload.stock_received_on
      assert_equal %w[KNOWN-SERIAL 123456789012345], [unit.serial_number, unit.imei]
      assert_equal %w[KNOWN-SERIAL 123456789012345], [unit.normalized_serial_number, unit.normalized_imei]
    end

    test 'stock input conversion rejects fractional quantities before reserving or receiving' do
      assert_raises(Conflict) { @receipt.existing!(product: @product, quantity: '1.5', received_on: Date.current, provenance: 'Verified stock') }
      need = create(:equipment_need, application: application_for_equipment, product: @product)
      error = assert_raises(Conflict) do
        @allocation.allocate!(needs: [need_row(need, '1.5')], application_versions: equipment_profile_versions(need.application))
      end
      assert_equal 'Enter whole positive allocation quantities.', error.message
      assert_equal 1, need.reload.remaining_quantity
    end

    test 'stock receipt accepts typed dates and rejects unreadable dates before changing inventory' do
      group = @bidding.create!(number: 'TYPED-RECEIPT', purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 1 }])
      order = award(group, number: 'TYPED-RECEIPT-PO', **shipping)
      @ordering.mark_sent!(order: order, sent_at: Date.current, expected_version: order.lock_version)
      args = { order: order, rows: [{ batch: order.equipment_items.order(:id).first.stock_receipt_batch, quantity: 1 }], expected_version: order.lock_version, item_versions: outstanding_versions(order) }
      assert_raises(Conflict) { @receipt.receive!(**args, received_on: '02/30/2026') }
      assert_empty order.equipment_items.where.not(stock_received_on: nil)
      @receipt.receive!(**args, received_on: Date.current.strftime('%m/%d/%Y'))
      assert_equal Date.current, order.equipment_items.sole.stock_received_on
    end

    test 'stock writers preserve a callback argument error instead of relabeling it as invalid input' do
      stock = @receipt.existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified stock').sole
      need = create(:equipment_need, application: application_for_equipment, product: @product)
      AuditEventService.stubs(:log).raises(ArgumentError, 'Callback contract failed')
      error = assert_raises(ArgumentError) do
        @allocation.allocate!(needs: [need_row(need, 1)], application_versions: equipment_profile_versions(need.application))
      end
      assert_equal 'Callback contract failed', error.message
      assert_nil stock.reload.application_id
      assert_equal 1, need.reload.remaining_quantity
      assert_no_difference 'EquipmentItem.count' do
        error = assert_raises(ArgumentError) do
          @receipt.existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified stock')
        end
        assert_equal 'Callback contract failed', error.message
      end
    end

    test 'partial stock allocation uses oldest receipt and ID tie then releases demand exactly once' do
      older = @receipt.existing!(product: @product, quantity: 2, received_on: 3.days.ago.to_date, provenance: 'Verified shelf count')
      newer = @receipt.existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified newer shelf count').sole
      application = application_for_equipment
      evaluation = create(:evaluation, :completed, application: application)
      need = create(:equipment_need, application: application, source_evaluation: evaluation, product: @product,
                                     remaining_quantity: 3, disability_setup_group: 'deaf')
      selected = @allocation.allocate!(needs: [need_row(need, 2)], application_versions: equipment_profile_versions(need.application))
      assert_equal older.map(&:id).sort, selected.map(&:id)
      assert_equal 1, need.reload.remaining_quantity
      assert_nil newer.reload.application_id
      assert_equal 2, EquipmentItem.reserved_stock.count
      assert_equal 3, need.application.equipment_items.active.count + need.remaining_quantity
      assert_equal [evaluation.id], selected.map(&:source_evaluation_id).uniq
      # Reproduce dates entered before the shipment requirement was enforced.
      EquipmentItem.where(id: selected.first.id).update_all(delivered_on: Date.current, installed_on: Date.current)
      @allocation.release!(item: selected.first.reload, expected_version: selected.first.lock_version, reason: 'Request remains wanted')
      assert_equal 2, need.reload.remaining_quantity
      assert_nil selected.first.reload.application_id
      assert_nil selected.first.source_evaluation_id
      assert_nil selected.first.delivered_on
      assert_nil selected.first.installed_on
      assert_equal older.first.stock_received_on, selected.first.stock_received_on
      assert_raises(Conflict) { @allocation.release!(item: selected.first, expected_version: selected.first.lock_version, reason: 'Repeat') }
      assert_equal 2, need.reload.remaining_quantity
    end

    test 'scarce stock and stale requests reject the complete reviewed allocation' do
      @receipt.existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified shelf count')
      need = create(:equipment_need, application: application_for_equipment, product: @product, remaining_quantity: 2, disability_setup_group: 'deaf')
      assert_raises(Conflict) { @allocation.allocate!(needs: [need_row(need, 2)], application_versions: equipment_profile_versions(need.application)) }
      assert_equal 2, need.reload.remaining_quantity
      assert_equal 1, EquipmentItem.available_stock.count
      stale = need_row(need, 1)
      need.update!(remaining_quantity: 1)
      assert_raises(Conflict) { @allocation.allocate!(needs: [stale], application_versions: equipment_profile_versions(need.application)) }
      assert_equal 1, EquipmentItem.available_stock.count
    end

    test 'detached replacement swap preserves physical identity and release restores the original demand' do
      stock = @receipt.existing!(product: @product, quantity: 2, received_on: 2.days.ago.to_date,
                                 provenance: 'Verified physical stock', identifiers: [{ serial_number: 'PHYSICAL-A' }, { serial_number: 'PHYSICAL-B' }])
      application = application_for_equipment
      evaluation = create(:evaluation, :completed, application: application)
      detached = create(:equipment_item, application: application, source_evaluation: evaluation, product: @product, purchase_order: nil,
                                         serial_number: 'ORIGINAL-RECOMMENDED-UNIT', disability_setup_group: 'deaf')
      allocated = @allocation.allocate!(items: [{ id: detached.id, lock_version: detached.lock_version }], application_versions: equipment_profile_versions(detached.application)).sole
      assert_equal allocated.id, detached.reload.replaced_by_equipment_item_id
      assert detached.withdrawn_at
      assert_equal evaluation.id, allocated.source_evaluation_id
      boundary = allocated.stock_allocated_at
      replacement = stock.find { |item| item.id != allocated.id }.reload
      EquipmentItem.where(id: allocated.id).update_all(delivered_on: Date.current, installed_on: Date.current)
      @allocation.swap!(item: allocated.reload, replacement_id: replacement.id, expected_version: allocated.lock_version,
                        replacement_version: replacement.lock_version, reason: 'Packing another verified box')
      assert_equal replacement.id, detached.reload.replaced_by_equipment_item_id
      assert_equal boundary, replacement.reload.stock_allocated_at
      assert_equal evaluation.id, replacement.source_evaluation_id
      assert_equal 'PHYSICAL-A', stock.first.reload.serial_number
      assert_equal 'PHYSICAL-B', stock.last.reload.serial_number
      assert_nil allocated.reload.application_id
      assert_nil allocated.source_evaluation_id
      assert_nil allocated.delivered_on
      assert_nil allocated.installed_on
      assert_nil replacement.delivered_on
      assert_nil replacement.installed_on
      @allocation.release!(item: replacement, expected_version: replacement.lock_version, reason: 'Restore direct fulfillment')
      assert_nil detached.reload.withdrawn_at
      assert_nil detached.replaced_by_equipment_item_id
      assert_equal 'ORIGINAL-RECOMMENDED-UNIT', detached.serial_number
      assert_equal evaluation.id, detached.source_evaluation_id
      assert_nil replacement.reload.source_evaluation_id
      assert_equal 2, EquipmentItem.available_stock.count
    end

    test 'replacing detached ICC equipment with MAT stock requires explicit funding acknowledgement' do
      application = approved_deafblind_application
      stock = @receipt.existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified MAT stock').sole
      detached = create(:equipment_item, application: application, product: @product, purchase_order: nil,
                                         funding_source: 'icanconnect', disability_setup_group: 'deafblind')
      selection = { id: detached.id, lock_version: detached.lock_version }
      assert_no_difference ['EquipmentItem.reserved_stock.count', 'Event.count'] do
        assert_raises(Conflict) { @allocation.allocate!(items: [selection], application_versions: equipment_profile_versions(application)) }
      end
      assert_nil detached.reload.withdrawn_at
      assert_nil stock.reload.application_id
      allocated = @allocation.allocate!(items: [selection], application_versions: equipment_profile_versions(application), confirm_mat_funding: true).sole
      assert_equal stock.id, allocated.id
      assert_equal 'mat', allocated.funding_source
      assert_equal 'icanconnect', detached.reload.funding_source
      assert_equal allocated.id, detached.replaced_by_equipment_item_id
      assert detached.withdrawn_at
    end

    test 'PO reuse requires matching purpose and source provenance cannot be rewritten' do
      direct = create(:purchase_order, sent_at: nil)
      group = @bidding.create!(number: 'STOCK-PURPOSE', purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 1 }])
      assert_raises(Conflict) do
        @ordering.call(bid_group: group, application_versions: equipment_bid_profile_versions(group), expected_version: group.lock_version, line_versions: line_versions(group),
                       existing: "#{direct.id}:#{direct.lock_version}")
      end
      assert_nil group.reload.purchase_order_id
      stock = @receipt.existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified inventory').sole
      assert_raises(ActiveRecord::RecordInvalid) { stock.update!(fulfillment_source: 'direct_vendor', application: application_for_equipment) }
      assert_equal 'existing_stock', stock.reload.fulfillment_source
    end

    test 'award rejects a changed reviewed destination without consuming any reserved demand' do
      need = create(:equipment_need, application: application_for_equipment, product: @product, disability_setup_group: 'deaf')
      group = @bidding.create!(number: 'PROFILE-AWARD', needs: [need_row(need, 1)])
      reviewed = equipment_bid_profile_versions(group)
      need.application.update!(shipping_address_1: 'Changed after review')
      assert_no_difference ['PurchaseOrder.count', 'EquipmentItem.count', 'Event.count'] do
        assert_raises(Conflict) do
          @ordering.call(bid_group: group, expected_version: group.lock_version, line_versions: line_versions(group),
                         application_versions: reviewed, purchase_order_attributes: { number: 'STALE-DESTINATION' })
        end
      end
      assert_equal 1, need.reload.remaining_quantity
      assert group.reload.open?
    end

    test 'stock allocation checks every reviewed application profile before assigning any unit' do
      @receipt.existing!(product: @product, quantity: 2, received_on: Date.current, provenance: 'Verified shelf stock')
      first = create(:equipment_need, application: application_for_equipment, product: @product, disability_setup_group: 'deaf')
      second = create(:equipment_need, application: application_for_equipment, product: @product, disability_setup_group: 'deaf')
      reviewed = equipment_profile_versions(first.application, second.application)
      second.application.update!(shipping_address_2: 'Changed after review')
      assert_no_difference ['EquipmentItem.reserved_stock.count', 'Event.count'] do
        assert_raises(Conflict) do
          @allocation.allocate!(needs: [need_row(first, 1), need_row(second, 1)], application_versions: reviewed)
        end
      end
      assert_equal [1, 1], [first.reload.remaining_quantity, second.reload.remaining_quantity]
      assert_equal 2, EquipmentItem.available_stock.where(product: @product).count
    end

    test 'receipt correction requires resolving an allocation and retains acquisition evidence' do
      stock = @receipt.existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified shelf count').sole
      correction = Correction.new(actor: @admin)
      correction.update_item!(item: stock, attributes: { stock_received_on: 1.day.ago.to_date }, expected_version: stock.lock_version, reason: 'Correct actual delivery date')
      assert_equal 1.day.ago.to_date, stock.reload.stock_received_on
      need = create(:equipment_need, application: application_for_equipment, product: @product, disability_setup_group: 'deaf')
      allocated = @allocation.allocate!(needs: [need_row(need, 1)], application_versions: Mutation.profile_versions([need.application])).sole
      assert_raises(ActiveRecord::RecordInvalid) do
        correction.update_item!(item: allocated, attributes: { stock_received_on: Date.current }, expected_version: allocated.lock_version, reason: 'Requires releasing first')
      end
      assert_equal 1.day.ago.to_date, allocated.reload.stock_received_on
      assert_equal 'existing_stock', allocated.fulfillment_source
      assert_equal 'Verified shelf count', allocated.intake_provenance
    end

    test 'correcting an unallocated purchased stock model retains original acquisition instructions' do
      group = @bidding.create!(number: 'ORIGINAL-STOCK-MODEL', purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 1 }])
      line = group.active_lines.sole
      order = award(group, number: 'STOCK-MODEL-PO', **shipping)
      @ordering.mark_sent!(order: order, sent_at: Date.current, expected_version: order.lock_version)
      receive(order, quantity: 1)
      unit = order.equipment_items.sole
      replacement = create(:product, manufacturer: 'Corrected manufacturer', model_number: 'VERIFIED-PHYSICAL-MODEL')
      Correction.new(actor: @admin).update_item!(item: unit, attributes: { product_id: replacement.id }, expected_version: unit.lock_version,
                                                 reason: 'Verified the model printed on the delivered device')
      assert_equal replacement, unit.reload.product
      assert_equal ProductIdentity.key(replacement.manufacturer, replacement.model_number), unit.manufacturer_model_identity
      assert_equal line.id, unit.acquisition_bid_group_line_id
      assert_equal order.id, unit.purchase_order_id
      assert_equal @product.id, line.reload.product_id
      assert_equal 'program_stock_po', unit.fulfillment_source
      event = unit.events.find_by!(action: 'equipment_item_corrected')
      assert_equal [@product.id, replacement.id], event.field_change_pairs['product_id']
      assert_equal 'Verified the model printed on the delivered device', event.metadata['reason']
      Correction.new(actor: @admin).update_item!(item: unit, attributes: { serial_number: 'VERIFIED-SERIAL' }, expected_version: unit.lock_version,
                                                 reason: 'Recorded the physical serial after verifying the model')
      assert_equal 'VERIFIED-SERIAL', unit.reload.serial_number
      assert_equal @product.id, line.reload.product_id
      need = create(:equipment_need, application: application_for_equipment, product: replacement, disability_setup_group: 'deaf')
      allocated = @allocation.allocate!(needs: [need_row(need, 1)], application_versions: equipment_profile_versions(need.application)).sole
      assert_raises(Conflict) do
        Correction.new(actor: @admin).update_item!(item: allocated, attributes: { product_id: @product.id }, expected_version: allocated.lock_version,
                                                   reason: 'Allocated stock must be released before another model correction')
      end
      assert_equal replacement.id, allocated.reload.product_id
    end

    test 'overdue income does not block an unfiled ICC detach but still blocks a new ICC award' do
      order, delivered = icc_order_with_unit
      application = delivered.application
      evaluation = create(:evaluation, :completed, application: application)
      pending = create(:equipment_item, application: application, product: delivered.product, purchase_order: order, source_evaluation: evaluation,
                                        funding_source: 'icanconnect', disability_setup_group: 'deafblind', unit_cost: 50)
      order.update!(invoice_total: 215)
      need = create(:equipment_need, application: application, disability_setup_group: 'deafblind')
      group = @bidding.create!(number: 'ICC-BEFORE-INCOME-DUE', funding_source: 'icanconnect', needs: [need_row(need, 1)])
      travel_to Date.current.next_year.in_time_zone.noon do
        assert application.reload.icanconnect_income_review_due?
        Correction.new(actor: @admin).update_item!(item: pending, attributes: {}, expected_version: pending.lock_version,
                                                   reason: 'Supplier cannot supply the unshipped device', operation: 'detach')
        assert_nil pending.reload.purchase_order_id
        assert_equal 'icanconnect', pending.funding_source
        assert_equal delivered.product_id, pending.product_id
        assert_equal evaluation.id, pending.source_evaluation_id
        assert pending.unfulfilled_since
        assert_equal order.id, pending.events.find_by!(action: 'equipment_item_corrected').metadata['purchase_order_ids'].sole
        assert_no_difference(['PurchaseOrder.count', 'EquipmentItem.count']) do
          error = assert_raises(Conflict) { award(group, number: 'ICC-INCOME-OVERDUE') }
          assert_includes error.message, 'updated income proof'
        end
        assert group.reload.open?
        assert_equal 1, need.reload.remaining_quantity
      end
    end

    test 'detaching an unshipped device cannot discard shared invoice evidence' do
      order, delivered = icc_order_with_unit
      pending = create(:equipment_item, application: delivered.application, product: delivered.product, purchase_order: order,
                                        funding_source: 'icanconnect', disability_setup_group: 'deafblind', unit_cost: 50)
      order.update!(invoice_total: 215)
      ::Icanconnect::FilingWriter.new(actor: @admin).mark!(selections: [filing_selection(delivered)], period: 'Test', external_reference: 'FILED-UNIT')
      assert_no_difference('Event.count') do
        error = assert_raises(Conflict) do
          Correction.new(actor: @admin).update_item!(item: pending, attributes: {}, expected_version: pending.lock_version,
                                                     reason: 'Try to remove a filed invoice member', operation: 'detach')
        end
        assert_includes error.message, 'shared invoice evidence'
      end
      assert_equal order.id, pending.reload.purchase_order_id
      assert_equal 2, order.reload.equipment_items.count
    end

    private

    def application_for_equipment
      create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment,
                                                        program_disability_groups: ['deaf'], equipment_needs_initialized_at: Time.current, **shipping)
    end

    def shipping
      { shipping_care_of: 'Confirmed recipient', shipping_address_1: '100 Delivery Street', shipping_address_2: 'Unit 2',
        shipping_city: 'Baltimore', shipping_state: 'MD', shipping_zip_code: '21201' }
    end

    def need_row(need, quantity)
      { id: need.id, quantity:, lock_version: need.lock_version }
    end

    def line_versions(group)
      group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] }
    end

    def award(group, **attributes)
      @ordering.call(bid_group: group, application_versions: equipment_bid_profile_versions(group), expected_version: group.lock_version, line_versions: line_versions(group), purchase_order_attributes: attributes)
    end

    def outstanding_versions(order)
      order.equipment_items.active.where(stock_received_on: nil).to_h { |item| [item.id.to_s, item.lock_version.to_s] }
    end

    def receive(order, quantity:)
      @receipt.receive!(order:, received_on: Date.current, rows: [{ batch: order.equipment_items.order(:id).first.stock_receipt_batch, quantity: }],
                        expected_version: order.lock_version, item_versions: outstanding_versions(order))
    end
  end
end
