# frozen_string_literal: true

require 'test_helper'

class DateInputNormalizerTest < ActiveSupport::TestCase
  ACCEPTED = {
    '9/9/2026' => Date.new(2026, 9, 9),
    '09/09/2026' => Date.new(2026, 9, 9),
    '09-09-2026' => Date.new(2026, 9, 9),
    '09.09.2026' => Date.new(2026, 9, 9),
    '09 09 2026' => Date.new(2026, 9, 9),
    '09092026' => Date.new(2026, 9, 9),
    '2026-09-09' => Date.new(2026, 9, 9),
    ' 9/9/2026 ' => Date.new(2026, 9, 9),
    # Month first, always: Date.parse reads both of these as October 9.
    '09/10/2026' => Date.new(2026, 9, 10),
    '09-10-2026' => Date.new(2026, 9, 10),
    '02/29/2024' => Date.new(2024, 2, 29),
    '12/31/1999' => Date.new(1999, 12, 31)
  }.freeze

  REJECTED = [
    '9/9/26',       # two-digit year: 1926 or 2026?
    '9/9-2026',     # mixed separators
    '9_9_2026',     # separator outside the allowed set
    '9a9a2026',
    '02/29/2026',   # not a leap year
    '02/30/2026',
    '13/01/2026',   # day-first reading of a real date
    '0909202',      # seven digits
    '909 2026',
    '2026/09/09',   # year first only in ISO form
    'January 15 1990',
    'not a date'
  ].freeze

  ACCEPTED.each do |input, expected|
    test "reads #{input.inspect} month first" do
      assert_equal expected, DateInputNormalizer.normalize(input)
      assert_not DateInputNormalizer.invalid?(input)
    end
  end

  REJECTED.each do |input|
    test "rejects #{input.inspect}" do
      assert_nil DateInputNormalizer.normalize(input)
      assert DateInputNormalizer.invalid?(input)
    end
  end

  test 'blank is neither a date nor invalid' do
    [nil, '', '   '].each do |input|
      assert_nil DateInputNormalizer.normalize(input)
      assert_not DateInputNormalizer.invalid?(input)
    end
  end

  test 'dates and times pass through as dates' do
    date = Date.new(1980, 9, 10)

    assert_equal date, DateInputNormalizer.normalize(date)
    assert_equal date, DateInputNormalizer.normalize(Time.zone.local(1980, 9, 10, 23, 0))
  end
end
