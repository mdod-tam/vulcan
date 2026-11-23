# frozen_string_literal: true

module Reports
  class Period
    MONTHS = [12, 6, 3].freeze

    attr_reader :length, :now, :months

    def initialize(length, now: Time.current)
      @length = MONTHS.find { |value| value.to_s == length.to_s } || MONTHS.first
      @now = now
      first = now.to_date.beginning_of_month << (@length - 1)
      @months = Array.new(@length) { |offset| first >> offset }
    end

    def range
      months.first.beginning_of_day..now
    end

    def dates
      months.first..now.to_date
    end

    def month_ends
      months.map { |month| [month.end_of_month.end_of_day, now].min }
    end

    def monthly(rows)
      by_month = rows.group_by { |date, _value| date.to_date.beginning_of_month }
      months.map { |month| by_month.fetch(month, []).sum(&:last) }
    end
  end
end
