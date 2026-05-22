# frozen_string_literal: true

require 'test_helper'

class FiscalYearTest < ActiveSupport::TestCase
  test 'current_start_year returns the July fiscal year start' do
    assert_equal 2025, FiscalYear.current_start_year(on: Date.new(2026, 5, 22))
    assert_equal 2026, FiscalYear.current_start_year(on: Date.new(2026, 7, 1))
  end

  test 'label_for_start_year uses fiscal year ending year' do
    assert_equal 'FY26', FiscalYear.label_for_start_year(2025)
  end

  test 'time_range is half-open' do
    start_date = Date.new(2025, 7, 1)
    end_date = Date.new(2025, 7, 31)
    range = FiscalYear.time_range(start_date, end_date)

    assert range.cover?(start_date.beginning_of_day)
    assert range.cover?(end_date.end_of_day)
    assert_not range.cover?(end_date.next_day.beginning_of_day)
  end

  test 'cohort_range_label describes YTD when before fiscal year end' do
    travel_to Date.new(2026, 5, 19) do
      label = FiscalYear.cohort_range_label(start_year: 2025, cohort_end_date: Date.current)
      assert_match(/FY26 YTD through May 19, 2026/, label)
    end
  end
end
