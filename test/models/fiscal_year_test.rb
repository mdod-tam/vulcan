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

  test 'quarter_for rotates calendar quarters so July starts Q1, in every month and across year boundaries' do
    expected = { 7 => 1, 8 => 1, 9 => 1, 10 => 2, 11 => 2, 12 => 2, 1 => 3, 2 => 3, 3 => 3, 4 => 4, 5 => 4, 6 => 4 }

    [2023, 2024, 2025, 2026].each do |year|
      expected.each do |month, quarter|
        assert_equal quarter, FiscalYear.quarter_for(Date.new(year, month, 1)), "#{year}-#{month}"
        assert_equal quarter, FiscalYear.quarter_for(Date.new(year, month, -1)), "#{year}-#{month} last day"
      end
    end
    assert_equal 3, FiscalYear.quarter_for(Date.new(2024, 2, 29))
  end

  test 'fiscal quarters begin and end on calendar quarter boundaries' do
    {
      Date.new(2025, 8, 15) => [Date.new(2025, 7, 1), Date.new(2025, 9, 30), 1],
      Date.new(2025, 11, 30) => [Date.new(2025, 10, 1), Date.new(2025, 12, 31), 2],
      Date.new(2026, 2, 28) => [Date.new(2026, 1, 1), Date.new(2026, 3, 31), 3],
      Date.new(2026, 6, 15) => [Date.new(2026, 4, 1), Date.new(2026, 6, 30), 4]
    }.each do |date, (quarter_start, quarter_end, fiscal_quarter)|
      assert_equal quarter_start, date.beginning_of_quarter
      assert_equal quarter_end, date.end_of_quarter
      assert_equal fiscal_quarter, FiscalYear.quarter_for(date)
    end
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
