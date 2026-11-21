# frozen_string_literal: true

require 'test_helper'

class EquipmentItemTest < ActiveSupport::TestCase
  test 'queue and portal scopes agree with direct and stock predicates across unsent sent shipped and unallocated states' do
    admin = create(:admin)
    application = create(:application, :approved, :with_all_proofs)
    product = create(:product)
    order = create(:purchase_order)
    attributes = { application: application, product: product, purchase_order: order }
    items = [create(:equipment_item, **attributes, purchase_order: nil),
             create(:equipment_item, **attributes, purchase_order: create(:purchase_order, sent_at: nil)),
             create(:equipment_item, **attributes), create(:equipment_item, **attributes, tracking_number: 'Label only'),
             create(:equipment_item, **attributes, shipped_at: Date.current, tracking_number: 'Sent package'),
             create(:equipment_item, **attributes, purchase_order: nil, withdrawn_at: Time.current)]
    stock = Equipment::StockReceipt.new(actor: admin).existing!(product: product, quantity: 2, received_on: Date.current - 1.day,
                                                                provenance: 'Verified on-hand devices')
    need = create(:equipment_need, application: application, product: product)
    Equipment::StockAllocation.new(actor: admin).allocate!(needs: [{ id: need.id, quantity: 1, lock_version: need.lock_version }], application_versions: equipment_profile_versions(application))
    items.concat(stock.map(&:reload))
    ids = items.map(&:id)
    assert_equal %w[needs_ordering ready_to_send_po awaiting_shipment awaiting_shipment shipped withdrawn awaiting_shipment available_stock], items.map(&:queue_status)
    assert_equal items.select(&:awaiting_shipment?).map(&:id).sort, EquipmentItem.ordered.where(id: ids).order(:id).pluck(:id)
    assert_equal items.select(&:portal_visible?).map(&:id).sort, EquipmentItem.portal_visible.where(id: ids).order(:id).pluck(:id)
    assert_equal [items.first.id], EquipmentItem.needs_ordering.where(id: ids).pluck(:id)
    assert_equal [items[4].id], EquipmentItem.shipped.where(id: ids).pluck(:id)
  end

  test 'tracking alone stays ordered and shipment requires a truthful date and tracking' do
    item = create(:equipment_item, tracking_number: 'Package-1')
    assert_equal 'awaiting_shipment', item.queue_status
    item.shipped_at = Date.current
    assert item.valid?
    item.shipped_at = item.purchase_order.sent_at - 1.day
    assert_not item.valid?
    assert item.errors[:shipped_at].any?
    item.shipped_at = Date.current + 1.day
    assert_not item.valid?
    item.shipped_at = Date.current
    item.tracking_number = nil
    assert_not item.valid?
    assert item.errors[:tracking_number].any?
  end

  test 'invalid typed shipment dates remain available for correction' do
    item = build(:equipment_item, shipped_at: '13/45/2026')
    assert_not item.valid?
    assert_equal '13/45/2026', item.rejected_shipped_at_input
  end

  test 'active serial uniqueness uses the exact catalog identity and survives shipment' do
    product = create(:product, manufacturer: ' Example Corp ', model_number: ' MODEL 1 ')
    first = create(:equipment_item, product: product, serial_number: ' ABC 123 ', shipped_at: Date.current, tracking_number: 'Package')
    duplicate = build(:equipment_item, product: product, serial_number: 'abc123')
    assert_not duplicate.valid?
    assert_includes duplicate.identity_conflicts, first
    assert_raises(ActiveRecord::RecordNotUnique) do
      # The database must also reject a writer racing the model validation.
      EquipmentItem.transaction(requires_new: true) { EquipmentItem.insert_all!([first.attributes.except('id')]) }
    end
  end

  test 'serial numbers can match across models of the same manufacturer' do
    first = create(:equipment_item, serial_number: 'MODEL-SERIAL')
    other_model = create(:product, manufacturer: first.product.manufacturer, model_number: 'Different model')
    candidate = build(:equipment_item, product: other_model, serial_number: 'model-serial')
    assert candidate.save
    candidate.product = first.product
    assert_not candidate.valid?
  end

  test 'active IMEI remains reserved by shipped and detached devices but withdrawal releases it' do
    item = create(:equipment_item, imei: '123 456 789 012 345')
    duplicate = build(:equipment_item, imei: '123456789012345')
    assert_not duplicate.valid?
    item.update!(purchase_order: nil)
    assert_equal 'needs_ordering', item.queue_status
    assert_not duplicate.valid?
    item.update!(withdrawn_at: Time.current)
    assert duplicate.valid?
    assert_equal 'withdrawn', item.queue_status
    assert_not build(:equipment_item, imei: '1234').valid?
  end

  test 'catalog edits do not silently rewrite recorded device identity' do
    item = create(:equipment_item)
    identity = item.manufacturer_model_identity
    assert_not item.product.update(model_number: 'Edited catalog model')
    item.update!(tracking_number: 'Package')
    assert_equal identity, item.reload.manufacturer_model_identity
    Equipment::Correction.new(actor: create(:admin)).update_item!(item: item, attributes: { product_id: create(:product).id },
                                                                  expected_version: item.lock_version, reason: 'Verified actual exact model')
    assert_not_equal identity, item.reload.manufacturer_model_identity
  end

  test 'device identifiers and normalized lookup values are encrypted in storage' do
    item = create(:equipment_item, imei: '123456789012345', serial_number: 'PrivateSerial', tracking_number: 'PrivatePackage')
    raw = EquipmentItem.connection.select_one("SELECT imei, normalized_imei, serial_number, normalized_serial_number, tracking_number FROM equipment_items WHERE id = #{item.id}")
    assert(raw.values.none? { |value| value.include?('123456789012345') || value.include?('PrivateSerial') || value.include?('PrivatePackage') })
    assert_equal item, EquipmentItem.find_by(normalized_imei: '123456789012345')
  end
end
