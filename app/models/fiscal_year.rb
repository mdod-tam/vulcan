# frozen_string_literal: true

# Fiscal year utilities (July 1 – June 30).
class FiscalYear
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
