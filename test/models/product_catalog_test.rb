# frozen_string_literal: true

require 'test_helper'

class ProductCatalogTest < ActiveSupport::TestCase
  test 'draft confirmation requires an exact model and availability includes confirmation' do
    draft = create(:product, model_confirmed: false, model_number: nil, manufacturer: nil)
    assert_not draft.available?
    assert_equal 'Draft', draft.availability_label
    draft.assign_attributes(model_confirmed: true, model_number: 'To be selected', manufacturer: 'Apple')
    assert_not draft.valid?
    assert_includes draft.errors[:model_confirmed], 'requires an exact manufacturer and model'
  end

  test 'confirmed normalized identities remain unique after discontinuation' do
    model = "Identity Model #{SecureRandom.hex(6)}"
    product = create(:product, manufacturer: 'Catalog Maker', model_number: model)
    product.archive!
    duplicate = build(:product, manufacturer: ' CATALOG   MAKER ', model_number: " #{model.upcase.gsub(' ', '   ')} ")
    assert_not duplicate.valid?
    assert duplicate.errors[:manufacturer_model_identity].any?
    assert_equal 'Discontinued', product.availability_label
    assert_not Product.available.exists?(product.id)
    assert Product.model_confirmed.exists?(product.id)
  end

  test 'category and program eligibility reject misleading classification' do
    product = build(:product, category: 'alerters_accessories_equipment', device_types: ['Smartphone'], eligible_disability_groups: ['invented'])
    assert_not product.valid?
    assert product.errors[:device_types].any?
    assert product.errors[:eligible_disability_groups].any?
    product.assign_attributes(device_types: ['Braille Device'], eligible_disability_groups: ['deafblind'])
    assert product.valid?
  end

  test 'JSON-only historical trial freezes a confirmed product identity and destruction' do
    product = create(:product)
    evaluation = create(:evaluation, status: :scheduled)
    evaluation.update!(products_tried: [{ 'product_id' => product.id.to_s, 'reaction' => 'Satisfied' }], recommended_product_ids: [])
    assert product.referenced?
    assert_not product.update(model_number: 'Another exact model')
    assert_not product.update(model_confirmed: false)
    product.reload
    assert_not product.destroy
    assert product.persisted?
    product.archive!
    assert product.archived?
  end

  test 'zero needs retain model identity' do
    product = create(:product)
    create(:equipment_need, product: product, remaining_quantity: 0)
    assert product.referenced?
    assert_not product.update(model_number: 'Replacement')
  end

  test 'training voucher items and unawarded stock bids all protect exact identity' do
    training_product = create(:product)
    create(:training_session, :completed, product_trained_on: training_product)
    voucher_product = create(:product)
    transaction = create(:voucher_transaction)
    transaction.voucher_transaction_products.create!(product: voucher_product, quantity: 1)
    stock_product = create(:product)
    group = BidGroup.create!(number: 'IDENTITY-STOCK-BID', purpose: 'program_stock')
    group.bid_group_lines.create!(product: stock_product, quantity: 2)
    item_product = create(:product)
    create(:equipment_item, product: item_product)
    [training_product, voucher_product, stock_product, item_product].each do |product|
      assert product.referenced?, "Reference missing for #{product.name}"
      assert_not product.update(model_number: 'Repurposed model')
      assert_not product.reload.destroy
    end
  end

  test 'MSRP remains missing until recorded and rejects negative amounts' do
    product = create(:product)
    assert_nil product.msrp
    assert product.update(msrp: '1234.56')
    assert_equal BigDecimal('1234.56'), product.reload.msrp
    assert_not product.update(msrp: -1)
    assert product.errors[:msrp].any?
  end

  test 'catalog keys cannot change after initialization' do
    product = create(:product, catalog_key: 'exact-original')
    assert_not product.update(catalog_key: 'renamed-key')
    assert_includes product.errors[:catalog_key], 'cannot be changed'
  end
end
