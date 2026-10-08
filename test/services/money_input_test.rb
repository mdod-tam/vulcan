# frozen_string_literal: true

require 'test_helper'

class MoneyInputTest < ActiveSupport::TestCase
  test 'reads dollars and cents without going through floating point' do
    { '125.50' => '125.5', '$1,234.50' => '1234.5', '7' => '7.0', '0.07' => '0.07', '1,000,000' => '1000000.0',
      ' $12.3 ' => '12.3' }.each do |input, expected|
      assert_equal BigDecimal(expected), MoneyInput.parse(input), input
    end
    assert_equal BigDecimal('0.1') + BigDecimal('0.2'), MoneyInput.parse('0.3')
  end

  test 'refuses fractional cents, misplaced commas, and anything that is not an amount' do
    ['10.005', '1,2', '12,34.00', '1,2345', '-5', 'abc', '', nil, '10.', '.50', '$', '1 000'].each do |input|
      assert_nil MoneyInput.parse(input), input.inspect
    end
  end
end
