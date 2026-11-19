# frozen_string_literal: true

require 'test_helper'
require Rails.root.join('db/seeds/products')

class ProductsSeedTest < ActiveSupport::TestCase
  test 'DeafBlind additions keep software distinct and an unresolved hardware family unavailable' do
    original = create(:product, name: 'Dot Pad Tactile Display', catalog_key: 'dot-dot-pad', manufacturer: 'Dot Inc.', model_number: 'Dot Pad')
    Seeds::Products.call
    keys = %w[dot-dot-pad-x freedom-scientific-jaws freedom-scientific-zoomtext tobii-dynavox-td-i-series
              tatum-robotics-tatum1 nwise-mymmx-db]
    products = Product.where(catalog_key: keys).index_by(&:catalog_key)
    assert_equal keys.sort, products.keys.sort
    products.each_value do |product|
      assert_equal ['deafblind'], product.eligible_disability_groups
      assert product.manufacturer.present?
      assert product.model_number.present?
      assert product.documentation_url.start_with?('https://')
      assert_nil product.msrp, "Unresolved pricing must remain unknown for #{product.catalog_key}"
    end
    dot_pad_x = products.fetch('dot-dot-pad-x')
    assert dot_pad_x.available?
    assert_equal 'DPA320X', dot_pad_x.model_number
    assert original.reload.archived?

    family = products.fetch('tobii-dynavox-td-i-series')
    assert_not family.model_confirmed?
    assert_not Product.available.exists?(family.id)
    %w[freedom-scientific-jaws freedom-scientific-zoomtext nwise-mymmx-db].each do |key|
      assert_equal 'alerters_accessories_equipment', products.fetch(key).category
      assert_equal ['Accessory'], products.fetch(key).device_types
    end
  end

  test 'missing keyed entries are created without matching another row by name' do
    existing = create(:product, name: 'Shared display label')
    attributes = {
      'catalog_key' => 'missing-key-test', 'category' => 'devices', 'name' => existing.name,
      'manufacturer' => 'Seed Test Maker', 'model_number' => 'Seed Model 77', 'model_confirmed' => true,
      'device_types' => ['Tablet'], 'eligible_disability_groups' => ['deaf']
    }
    Seeds::Products.stub(:catalog, [attributes]) do
      assert_difference 'Product.count', 1 do
        Seeds::Products.call
      end
      assert_no_difference 'Product.count' do
        Seeds::Products.call
      end
    end
    seeded = Product.find_by!(catalog_key: 'missing-key-test')
    assert_not_equal existing.id, seeded.id
    assert_equal 'Seed Model 77', seeded.model_number
  end

  test 'confirmed SquareGlow Adapter is available while Bellman Visit stays in draft' do
    Seeds::Products.call
    visit = Product.find_by!(catalog_key: 'bellman-symfon-visit-alerting-system')
    assert_not visit.model_confirmed?
    assert_not Product.available.exists?(visit.id)

    adapter = Product.available.find_by!(catalog_key: 'squareglow-adapter')
    assert_equal 'Adapter', adapter.model_number
    assert_equal BigDecimal('9.99'), adapter.msrp
  end

  test 'catalog offers selected models and excludes direct Hamilton and discontinued equipment' do
    Seeds::Products.call
    expected_prices = { 'apple-macbook-air-13-inch-m5' => BigDecimal('1299.00'),
                        'apple-macbook-air-15-inch-m5' => BigDecimal('1499.00') }
    laptops = Product.available.where(catalog_key: expected_prices.keys).index_by(&:catalog_key)
    assert_equal expected_prices.keys.sort, laptops.keys.sort
    expected_prices.each do |key, price|
      product = laptops.fetch(key)
      assert_equal 'Apple', product.manufacturer
      assert_equal ['Computer'], product.device_types
      assert_equal ['deafblind'], product.eligible_disability_groups
      assert_equal price, product.msrp
    end
    assert_not Product.exists?(catalog_key: 'macbook-laptop-model-to-be-selected')
    assert_not Product.exists?(catalog_key: 'hamilton-captel-captioned-telephone')
    assert_not Product.exists?(catalog_key: 'clearsounds-csc600-amplified-telephone')
    assert_not Product.exists?(manufacturer: 'Clarity', model_number: 'P300-SP')
    photo_phone = Product.find_by!(catalog_key: 'serene-innovations-hd-40p-photo-speakerphone')
    assert_equal 'Serene Innovations', photo_phone.manufacturer
    assert_equal 'HD-40P', photo_phone.model_number
    assert_equal BigDecimal('139.95'), photo_phone.msrp
    assert_includes photo_phone.device_types, 'Memory Aid Device'
    assert_not_includes photo_phone.eligible_disability_groups, 'speech'
    assert photo_phone.available?
    hco = Product.find_by!(catalog_key: 'clarity-p300-hco-hearing-carry-over-kit')
    assert_equal 'Clarity', hco.manufacturer
    assert_equal 'P300-HCO', hco.model_number
    assert_equal BigDecimal('369.95'), hco.msrp
    assert_equal ['Speech Device'], hco.device_types
    assert_equal ['speech'], hco.eligible_disability_groups
    assert hco.available?
    assert_equal 1, Product.where(manufacturer: 'Atos Medical', model_number: 'TruTone EMOTE').count
  end

  test 'keyed catalog refresh restores seeded attributes and preserves unseeded fields resources and discontinuation' do
    missing = Seeds::Products.required_keys - Product.where(catalog_key: Seeds::Products.required_keys).pluck(:catalog_key)
    assert_difference 'Product.count', missing.size do
      Seeds::Products.call
    end
    product = Product.find_by!(catalog_key: 'apple-iphone-18-pro')
    assert_equal BigDecimal('1199.00'), product.msrp
    supplied_prices = {
      'squareglow-smart-homekit' => BigDecimal('415.00'), 'squareglow-smart-strobe-alert' => BigDecimal('79.99'),
      'squareglow-adapter' => BigDecimal('9.99'), 'squareglow-chime-kit' => BigDecimal('49.99')
    }
    assert_equal supplied_prices, Product.where(catalog_key: supplied_prices.keys).pluck(:catalog_key, :msrp).to_h
    beep = Product.find_by!(catalog_key: 'blindshell-beep-product-name-to-confirm')
    assert_equal 'Beep', beep.model_number
    assert beep.model_confirmed?
    assert_equal BigDecimal('30.00'), beep.msrp
    assert_equal 'Sonic Alert', Product.find_by!(catalog_key: 'homeaware-home-alerting-system').manufacturer
    assert_nil Product.find_by!(catalog_key: 'large-print-keyboard').msrp
    selected_manufacturers = {
      'telitalk-kit-product-specifications-to-confirm' => 'Atos Medical', 'large-print-keyboard' => 'LogicKeyboard',
      'accessible-stylus' => 'Enabling Devices', 'android-tablet-model-to-be-selected' => 'Samsung',
      'windows-laptop-model-to-be-selected' => nil
    }
    assert_equal selected_manufacturers,
                 Product.where(catalog_key: selected_manufacturers.keys).pluck(:catalog_key, :manufacturer).to_h
    stylus = Product.find_by!(catalog_key: 'accessible-stylus')
    assert_equal '9079', stylus.model_number
    assert_equal BigDecimal('80.95'), stylus.msrp
    assert stylus.available?
    strap = Product.find_by!(catalog_key: 'moshi-2-in-1-wrist-body-strap-with-adapter-midnight-gray')
    assert_equal '2-in-1 Wrist/Body Strap with Adapter / Midnight Gray', strap.name
    assert_equal 'Moshi', strap.manufacturer
    assert_equal '99MO2252613', strap.model_number
    assert_equal BigDecimal('39.95'), strap.msrp
    assert_equal 'alerters_accessories_equipment', strap.category
    assert_equal ['Accessory'], strap.device_types
    assert_equal Product::PROGRAM_GROUPS.keys.sort, strap.eligible_disability_groups.sort
    assert_equal 'https://us.moshi.com/products/2-in-1-wrist-body-strap-with-adapter?variant=47163633238154', strap.documentation_url
    assert strap.available?
    mount_manufacturers = { 'wheelchair-compatible-device-mount' => 'Rehadapt',
                            'adjustable-tablet-mount' => 'Oak Hill Brands Corp.',
                            'flexible-smartphone-mount' => 'Oak Hill Brands Corp.' }
    mount_manufacturers.each do |key, manufacturer|
      mount = Product.find_by!(catalog_key: key)
      assert_equal manufacturer, mount.manufacturer
      assert_not mount.model_confirmed?
      assert_nil mount.model_number
      assert_nil mount.msrp
    end
    product.update!(name: 'Staff display name', description: 'Staff description', msrp: '1250.50', archived_at: 1.day.ago)
    archived_at = product.archived_at
    resource = create(:product_resource, product: product)
    unknown_price = Product.find_by!(catalog_key: 'large-print-keyboard')
    unknown_price.update!(msrp: '100.00')
    manual = create(:product, msrp: '123.45')
    manual_attributes = manual.attributes
    assert_no_difference 'Product.count' do
      Seeds::Products.call
    end
    assert_equal 'Apple iPhone 18 Pro', product.reload.name
    assert_equal 'Staff description', product.description
    assert_equal BigDecimal('1199.00'), product.msrp
    assert product.archived?
    assert_equal archived_at, product.archived_at
    assert product.product_resources.exists?(resource.id)
    assert_nil unknown_price.reload.msrp
    assert_equal manual_attributes, manual.reload.attributes
    assert_equal 54, Product.where(catalog_key: Seeds::Products.required_keys).count
    assert Product.exists?(model_confirmed: false, catalog_key: Seeds::Products.required_keys)
  end

  test 'removed keyed products are discontinued once while their history and manual products remain' do
    Seeds::Products.call
    retired = create(:product, catalog_key: 'macbook-laptop-model-to-be-selected')
    need = create(:equipment_need, product: retired)
    resource = create(:product_resource, product: retired)
    manual = create(:product, name: retired.name)
    manual_attributes = manual.attributes

    assert_no_difference ['Product.count', 'EquipmentNeed.count', 'ProductResource.count'] do
      Seeds::Products.call
    end
    assert retired.reload.archived?
    assert_not Product.available.exists?(retired.id)
    assert_equal retired.id, need.reload.product_id
    assert retired.product_resources.exists?(resource.id)
    archived_at = retired.archived_at

    assert_no_difference ['Product.count', 'EquipmentNeed.count', 'ProductResource.count'] do
      Seeds::Products.call
    end
    assert_equal archived_at, retired.reload.archived_at
    assert_equal manual_attributes, manual.reload.attributes
    assert manual.available?
  end

  test 'a referenced exact-model change rejects the refresh without partial catalog writes' do
    product = create(:product, catalog_key: 'referenced-seed-model')
    need = create(:equipment_need, product: product)
    old_model = product.model_number
    unlisted = create(:product, catalog_key: 'retirement-must-roll-back')
    entries = [
      { 'catalog_key' => 'new-model-must-roll-back', 'name' => 'New seed model', 'manufacturer' => 'Seed Maker',
        'model_number' => 'NEW-1', 'model_confirmed' => true, 'category' => 'devices',
        'device_types' => ['Tablet'], 'eligible_disability_groups' => ['deaf'] },
      { 'catalog_key' => product.catalog_key, 'model_number' => 'Different exact model' }
    ]

    Seeds::Products.stub(:catalog, entries) do
      assert_no_difference 'Product.count' do
        error = assert_raises(ActiveRecord::RecordInvalid) { Seeds::Products.call }
        assert_includes error.record.errors.full_messages.join, 'A referenced exact model cannot be changed'
      end
    end
    assert_equal old_model, product.reload.model_number
    assert_equal product.id, need.reload.product_id
    assert_not unlisted.reload.archived?
    assert_not Product.exists?(catalog_key: 'new-model-must-roll-back')
  end
end
