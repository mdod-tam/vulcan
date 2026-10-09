# frozen_string_literal: true

require 'test_helper'

class VendorTaxRecordTest < ActiveSupport::TestCase
  test 'tax IDs round trip through the shared User owner and use different ciphertext for equal values' do
    first = create(:vendor, business_tax_id: '123456789')
    second = create(:vendor, business_tax_id: '123456789')

    assert_includes User.encrypted_attributes, :business_tax_id
    assert_equal '123456789', User.find(first.id).business_tax_id
    assert_equal '123456789', first.reload.business_tax_id
    ciphertexts = [first, second].map do |vendor|
      User.connection.select_value("SELECT business_tax_id FROM users WHERE id = #{vendor.id}")
    end
    ciphertexts.each { |ciphertext| assert_not_includes ciphertext, '123456789' }
    assert_not_equal(*ciphertexts)
  end

  test 'blank replacement input keeps a persisted tax ID and a supplied replacement updates it' do
    vendor = create(:vendor, business_tax_id: '123456789')

    ['', ' ', nil].each do |blank|
      vendor.update!(business_tax_id: blank)
      assert_equal '123456789', vendor.reload.business_tax_id
    end
    vendor.update!(business_tax_id: '987654321')

    assert_equal '987654321', vendor.reload.business_tax_id
    assert_equal '•••••4321', vendor.masked_business_tax_id
  end

  test 'a new vendor still needs a tax ID' do
    vendor = build(:vendor, business_tax_id: '')

    assert_not vendor.valid?
    assert_includes vendor.errors[:business_tax_id], "can't be blank"
  end
end
