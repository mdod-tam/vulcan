# frozen_string_literal: true

require 'test_helper'

class EquipmentItemTest < ActiveSupport::TestCase
  test 'tracking alone stays ordered and shipment requires a truthful date and tracking' do
    item = create(:equipment_item, tracking_number: 'Package-1')
    assert_equal 'ordered', item.queue_status
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

  test 'active serial uniqueness spans duplicate catalog entries and survives shipment' do
    product = create(:product, manufacturer: ' Example Corp ', model_number: ' MODEL 1 ')
    first = create(:equipment_item, product: product, serial_number: ' ABC 123 ', shipped_at: Date.current, tracking_number: 'Package')
    duplicate_product = create(:product, manufacturer: 'example corp', model_number: 'model 1')
    duplicate = build(:equipment_item, product: duplicate_product, serial_number: 'abc123')
    assert_not duplicate.valid?
    assert_includes duplicate.identity_conflicts, first
    assert_raises(ActiveRecord::RecordNotUnique) do
      # The database must also reject a writer racing the model validation.
      EquipmentItem.transaction(requires_new: true) { EquipmentItem.insert_all!([first.attributes.except('id')]) }
    end
  end

  test 'potential serial matches on another model need an acknowledgment and confirmed duplicates remain blocked' do
    first = create(:equipment_item, serial_number: 'MODEL-SERIAL')
    other_model = create(:product, manufacturer: first.product.manufacturer, model_number: 'Different model')
    candidate = build(:equipment_item, product: other_model, serial_number: 'model-serial')
    assert_not candidate.valid?
    candidate.serial_duplicate_reason = 'Manufacturer confirmed this serial is reused across its model range.'
    assert candidate.valid?
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
    item.product.update!(model_number: 'Edited catalog model')
    item.update!(tracking_number: 'Package')
    assert_equal identity, item.reload.manufacturer_model_identity
    item.update!(product: create(:product))
    assert_not_equal identity, item.reload.manufacturer_model_identity
  end

  test 'device identifiers and normalized lookup values are encrypted in storage' do
    item = create(:equipment_item, imei: '123456789012345', serial_number: 'PrivateSerial', tracking_number: 'PrivatePackage')
    raw = EquipmentItem.connection.select_one("SELECT imei, normalized_imei, serial_number, normalized_serial_number, tracking_number FROM equipment_items WHERE id = #{item.id}")
    assert(raw.values.none? { |value| value.include?('123456789012345') || value.include?('PrivateSerial') || value.include?('PrivatePackage') })
    assert_equal item, EquipmentItem.find_by(normalized_imei: '123456789012345')
  end
end
