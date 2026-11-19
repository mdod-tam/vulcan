# frozen_string_literal: true

require 'test_helper'

module Equipment
  class PurchaseCostsTest < ActiveSupport::TestCase
    include IcanconnectTestSupport

    setup do
      @admin = create(:admin)
      @order = create(:purchase_order)
      @first = create(:equipment_item, purchase_order: @order, product: create(:product, msrp: 999))
      @second = create(:equipment_item, purchase_order: @order)
    end

    test 'actual unit prices stay distinct from MSRP and unknown values stay missing' do
      save_costs('845.25', '')
      assert_equal BigDecimal('845.25'), @first.reload.unit_cost
      assert_equal BigDecimal('999'), @first.product.msrp
      assert_nil @second.reload.unit_cost
      assert Event.exists?(action: 'equipment_purchase_cost_recorded', auditable: @first)
    end

    test 'invalid or stale prices reject every reviewed unit atomically' do
      assert_raises(Conflict) { save_costs('845', '-1') }
      assert_nil @first.reload.unit_cost
      rows = cost_rows('845', '10')
      @second.update!(unit_cost: 11)
      assert_raises(Conflict) { PurchaseCosts.update!(order: @order, rows: rows, expected_version: @order.lock_version, actor: @admin) }
      assert_nil @first.reload.unit_cost
      assert_equal BigDecimal('11'), @second.reload.unit_cost
    end

    test 'supplier name is recorded with the reviewed costs and rolls back if a unit price is invalid' do
      assert_raises(Conflict) do
        PurchaseCosts.update!(order: @order, rows: cost_rows('100', '-1'), expected_version: @order.lock_version, actor: @admin,
                              order_attributes: { vendor_name: 'Actual supplier' })
      end
      assert_nil @order.reload.vendor_name
      assert_not Event.exists?(auditable: @order, action: 'equipment_supplier_recorded')
      @first.reload
      @second.reload
      PurchaseCosts.update!(order: @order, rows: cost_rows('100', '50'), expected_version: @order.lock_version, actor: @admin,
                            order_attributes: { vendor_name: 'Actual supplier' })
      assert_equal 'Actual supplier', @order.reload.vendor_name
      assert Event.exists?(auditable: @order, action: 'equipment_supplier_recorded')
    end

    test 'typed price parsing rejects garbage and fractional cents without partial prices supplier edits or audits' do
      ['garbage', '12abc', '12.345', '$1,2', BigDecimal('12.345')].each do |invalid|
        versions = [@first.reload.lock_version, @second.reload.lock_version, @order.reload.lock_version]
        assert_no_difference 'Event.count' do
          assert_raises(Conflict) do
            PurchaseCosts.update!(order: @order, rows: cost_rows('$1,234.50', invalid), expected_version: @order.lock_version,
                                  actor: @admin, order_attributes: { vendor_name: 'Should roll back' })
          end
        end
        assert_nil @first.reload.unit_cost
        assert_nil @second.reload.unit_cost
        assert_nil @order.reload.vendor_name
        assert_equal versions, [@first.lock_version, @second.lock_version, @order.lock_version]
      end
      save_costs('$1,234.50', '0')
      assert_equal BigDecimal('1234.50'), @first.reload.unit_cost
      assert_equal BigDecimal('0'), @second.reload.unit_cost
    end

    test 'single unit financial edits use strict parsing and cannot bypass filed invoice locks' do
      writer = Icanconnect::FilingWriter.new(actor: @admin)
      ['not a price', '12.345'].each do |invalid|
        assert_no_difference 'Event.count' do
          assert_raises(Conflict) { writer.update_evidence!(record: @first, attributes: { unit_cost: invalid }, lock_version: @first.lock_version) }
        end
        assert_nil @first.reload.unit_cost
      end
      order, unit = icc_order_with_unit
      writer.mark!(selections: [filing_selection(unit)], period: 'Filed invoice', external_reference: 'FILED-PRICE')
      version = unit.reload.lock_version
      assert_no_difference 'Event.count' do
        assert_raises(ActiveRecord::RecordInvalid) do
          PurchaseCosts.update!(order: order, rows: [{ id: unit.id, lock_version: version, unit_cost: '151.00' }],
                                expected_version: order.reload.lock_version, actor: @admin)
        end
        assert_raises(ActiveRecord::RecordInvalid) do
          PurchaseCosts.update_unit!(item: unit.reload, amount: '151.00', expected_version: version, actor: @admin)
        end
      end
      assert_equal 150, unit.reload.unit_cost
      assert_equal version, unit.lock_version
      assert unit.icc_claimed?
    end

    test 'financial review and PO costs use the same price audit and preserve atomic evidence updates' do
      writer = Icanconnect::FilingWriter.new(actor: @admin)
      version = @first.lock_version
      assert_no_difference -> { Event.where(auditable: @first).count } do
        assert_raises(ActiveRecord::RecordInvalid) do
          writer.update_evidence!(record: @first, attributes: { unit_cost: '25', delivered_on: Date.current + 1 }, lock_version: version)
        end
      end
      assert_nil @first.reload.unit_cost
      assert_equal version, @first.lock_version

      writer.update_evidence!(record: @first, attributes: { unit_cost: '25' }, lock_version: version)
      event = Event.where(auditable: @first, action: 'equipment_purchase_cost_recorded').sole
      assert_nil event.field_change_pairs.fetch('unit_cost').first
      assert_equal 25, event.field_change_pairs.fetch('unit_cost').last.to_d
      assert_equal [@first.id], event.metadata.fetch('equipment_item_ids')
      assert_not Event.exists?(auditable: @first, action: 'icc_financial_evidence_updated')
      assert_raises(ActiveRecord::StaleObjectError) do
        writer.update_evidence!(record: @first, attributes: { unit_cost: '26' }, lock_version: version)
      end

      @first.reload
      save_costs('30', '40')
      assert_equal 30, @first.reload.unit_cost
      assert_equal 2, Event.where(auditable: @first, action: 'equipment_purchase_cost_recorded').count
    end

    private

    def save_costs(first, second)
      PurchaseCosts.update!(order: @order, rows: cost_rows(first, second), expected_version: @order.lock_version, actor: @admin)
    end

    def cost_rows(first, second)
      [[@first, first], [@second, second]].map { |item, cost| { id: item.id, lock_version: item.lock_version, unit_cost: cost } }
    end
  end
end
