# frozen_string_literal: true

require 'test_helper'

class MileageRateTest < ActiveSupport::TestCase
  test 'rates accept exact thousandths including zero and reject malformed or rounded inputs' do
    { '0' => '0', '0.725' => '0.725', '999.999' => '999.999', BigDecimal('0.7') => '0.7' }.each do |input, expected|
      assert_equal BigDecimal(expected), MileageRate.parse(input)
      assert MileageRate.new(effective_on: '07/01/2026', dollars_per_mile: input).valid?
    end
    [nil, '', '-0.001', '0.7251', '0.7000', '1000', '1e-3', 'NaN', '12oops'].each do |input|
      assert_nil MileageRate.parse(input), "Accepted #{input.inspect}"
      rate = MileageRate.new(effective_on: '07/01/2026', dollars_per_mile: input)
      assert_not rate.valid?, "Accepted #{input.inspect}"
      assert rate.errors[:dollars_per_mile].any?
    end
  end

  test 'effective dates use typed input and remain unique in both the model and database' do
    [nil, '', '02/30/2026', '2026', '9/9/26'].each do |date|
      rate = MileageRate.new(effective_on: date, dollars_per_mile: '0.725')
      assert_not rate.valid?, "Accepted effective date #{date.inspect}"
      assert rate.errors[:effective_on].any?
      assert_equal date, rate.rejected_effective_on_input if date.present?
    end
    rate = MileageRate.create!(effective_on: '07/01/2026', dollars_per_mile: '0.725')
    assert_equal Date.new(2026, 7, 1), rate.effective_on
    duplicate = MileageRate.new(effective_on: rate.effective_on, dollars_per_mile: '0.700')
    assert_not duplicate.valid?
    assert duplicate.errors[:effective_on].any?
    assert_raises(ActiveRecord::RecordNotUnique) do
      MileageRate.transaction(requires_new: true) { MileageRate.insert_all!([rate.attributes.except('id')]) }
    end
  end

  test 'service date lookup applies the latest effective rate without calendar year expiry or early future rates' do
    MileageRate.create!(effective_on: Date.new(2026, 1, 1), dollars_per_mile: '0.725')
    MileageRate.create!(effective_on: Date.new(2026, 7, 1), dollars_per_mile: '0.760')
    MileageRate.create!(effective_on: Date.new(2027, 8, 1), dollars_per_mile: '0.800')

    assert_nil MileageRate.for_service_date(Date.new(2025, 12, 31))
    assert_equal BigDecimal('0.725'), MileageRate.for_service_date(Date.new(2026, 1, 1))
    assert_equal BigDecimal('0.725'), MileageRate.for_service_date('06/30/2026')
    assert_equal BigDecimal('0.760'), MileageRate.for_service_date(Date.new(2026, 7, 1))
    assert_equal BigDecimal('0.760'), MileageRate.for_service_date(Date.new(2027, 7, 31))
    assert_equal BigDecimal('0.800'), MileageRate.for_service_date(Date.new(2027, 8, 1))
    assert_equal BigDecimal('0.800'), MileageRate.for_service_date(Date.new(2030, 1, 1))
    assert_nil MileageRate.for_service_date(nil)
    assert_nil MileageRate.for_service_date('not a date')
  end
end
