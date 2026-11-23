# frozen_string_literal: true

module Reports
  class MfrReport
    MEASURES = {
      'People who applied for accessible telecommunication equipment from MAT' => 'People who applied',
      'People who received equipment from MAT' => 'People who received equipment',
      'Devices distributed through MAT' => 'Devices distributed'
    }.freeze

    attr_reader :year

    def initialize(year, today: Date.current)
      @latest = FiscalYear.current_start_year(on: today) - 1
      @year = years.find { |candidate| candidate.to_s == year.to_s } || @latest
    end

    def years
      @latest.downto(first_year)
    end

    def comparison_rows
      preceding = year - 1
      rows = MEASURES.keys.zip(counts(year), counts(preceding))
      vouchers = [year, preceding].map { |start_year| Voucher.where(issued_at: fiscal_year_range(start_year)).count }
      rows << ['Vouchers issued', *vouchers] if vouchers.any?(&:positive?)
      rows
    end

    def counts(start_year)
      time_range = fiscal_year_range(start_year)
      deliveries = mat_deliveries.where(delivered_on: time_range.begin.to_date...time_range.end.to_date)
      recipients, units = deliveries.joins(:application).pick(Arel.sql('COUNT(DISTINCT applications.user_id)'), Arel.sql('COUNT(*)'))
      [Submissions.within(time_range).distinct.count(:user_id), recipients, units]
    end

    private

    def fiscal_year_range(start_year)
      FiscalYear.time_range(FiscalYear.start_date_for(start_year), FiscalYear.end_date_for(start_year))
    end

    def mat_deliveries
      EquipmentItem.shipped.where(funding_source: 'mat').where.not(delivered_on: nil)
    end

    def first_year
      @first_year ||= begin
        dates = [Submissions.online_transitions.minimum(:changed_at),
                 Application.submission_method_paper.submitted.minimum(:created_at),
                 mat_deliveries.minimum(:delivered_on), Voucher.minimum(:issued_at)]
        first = dates.compact.map(&:to_date).min
        [@latest - 1, first && FiscalYear.current_start_year(on: first)].compact.min
      end
    end
  end
end
