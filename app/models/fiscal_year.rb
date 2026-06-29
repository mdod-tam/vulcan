# frozen_string_literal: true

# Fiscal year utilities (July 1 – June 30).
class FiscalYear
  FISCAL_QUARTERS = {
    1 => { months: [7, 8, 9], start: [0, 7, 1], end: [0, 9, 30] },
    2 => { months: [10, 11, 12], start: [0, 10, 1], end: [0, 12, 31] },
    3 => { months: [1, 2, 3], start: [1, 1, 1], end: [1, 3, 31] },
    4 => { months: [4, 5, 6], start: [1, 4, 1], end: [1, 6, 30] }
  }.freeze

  def self.current_start_year(on: Date.current)
    on.month >= 7 ? on.year : on.year - 1
  end

  def self.start_date_for(start_year)
    Date.new(start_year, 7, 1)
  end

  def self.end_date_for(start_year)
    Date.new(start_year + 1, 6, 30)
  end

  # Half-open: inclusive start, exclusive end.
  def self.time_range(fy_start_date, fy_end_date)
    fy_start_date.beginning_of_day...fy_end_date.next_day.beginning_of_day
  end

  def self.label_for_start_year(start_year)
    "FY#{(start_year + 1).to_s[-2..]}"
  end

  def self.quarter_for(date)
    FISCAL_QUARTERS.find { |_, quarter| quarter[:months].include?(date.month) }.first
  end

  def self.quarter_start_date(date)
    year_offset, month, day = FISCAL_QUARTERS.fetch(quarter_for(date)).fetch(:start)
    Date.new(current_start_year(on: date) + year_offset, month, day)
  end

  def self.quarter_end_date(date)
    year_offset, month, day = FISCAL_QUARTERS.fetch(quarter_for(date)).fetch(:end)
    Date.new(current_start_year(on: date) + year_offset, month, day)
  end

  def self.cohort_range_label(start_year:, cohort_end_date:)
    fy_label = label_for_start_year(start_year)
    fy_end = end_date_for(start_year)
    if cohort_end_date < fy_end
      "#{fy_label} YTD through #{cohort_end_date.strftime('%B %-d, %Y')}"
    else
      start_date = start_date_for(start_year)
      "#{fy_label} (#{start_date.strftime('%B %-d, %Y')} – #{cohort_end_date.strftime('%B %-d, %Y')})"
    end
  end
end
