# frozen_string_literal: true

require 'test_helper'

class EquipmentNeedTest < ActiveSupport::TestCase
  setup do
    FeatureFlag.disable!(:vouchers_enabled)
    @application = create(:application, :approved)
    @product = create(:product)
  end

  test 'zero is retained and quantities must be nonnegative integers' do
    need = EquipmentNeed.create!(application: @application, product: @product, remaining_quantity: 0)
    assert_not_includes EquipmentNeed.remaining, need

    [-1, 1.5, nil].each do |quantity|
      need.remaining_quantity = quantity
      assert_not need.valid?
      assert need.errors[:remaining_quantity].present?
    end
  end

  test 'an application has one row per catalog product including a zero row' do
    EquipmentNeed.create!(application: @application, product: @product, remaining_quantity: 0)
    duplicate = EquipmentNeed.new(application: @application, product: @product, remaining_quantity: 1)

    assert_not duplicate.valid?
    assert duplicate.errors[:product_id].present?
  end

  test 'the database rejects duplicate rows and negative quantities' do
    need = EquipmentNeed.create!(application: @application, product: @product, remaining_quantity: 0)
    assert_raises ActiveRecord::RecordNotUnique do
      EquipmentNeed.transaction(requires_new: true) do
        EquipmentNeed.insert_all!([{ application_id: @application.id, product_id: @product.id, remaining_quantity: 1 }])
      end
    end
    assert_raises ActiveRecord::StatementInvalid do
      EquipmentNeed.transaction(requires_new: true) { need.update_columns(remaining_quantity: -1) }
    end
    assert_equal 0, need.reload.remaining_quantity
  end

  test 'provenance cannot refer to an evaluation on another application' do
    evaluation = create(:evaluation)
    need = EquipmentNeed.new(application: @application, product: @product, remaining_quantity: 1, source_evaluation: evaluation)

    assert_not need.valid?
    assert_equal ['must belong to this application'], need.errors[:source_evaluation]
  end

  test 'catalog records with purchasing history cannot be destroyed' do
    EquipmentNeed.create!(application: @application, product: @product, remaining_quantity: 0)

    assert_not @product.destroy
    assert Product.exists?(@product.id)
  end
end
