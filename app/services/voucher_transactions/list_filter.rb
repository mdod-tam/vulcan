# frozen_string_literal: true

module VoucherTransactions
  # Rows, totals and the complete CSV share this vendor-scoped purchase query.
  class ListFilter
    attr_reader :errors

    def initialize(vendor:, params:, now: Time.current)
      @vendor = vendor
      @params = params
      @today = now.in_time_zone(Rails.application.config.time_zone).to_date
      @errors = []
    end

    def call
      scope = @vendor.voucher_transactions.preload(:shipments, :invoice, voucher: { application: :user })
                     .order(processed_at: :desc, id: :desc)
      scope = scope.needing_shipping_details if @params[:needs_shipping_details] == '1'
      dates = selected_dates
      return scope.none if errors.any?
      return scope unless dates

      first, last = dates
      zone = Time.find_zone!(Rails.application.config.time_zone)
      scope.where(processed_at: first.in_time_zone(zone)...last.tomorrow.in_time_zone(zone))
    end

    private

    def selected_dates
      case @params[:period]
      when nil, '' then nil
      when 'today' then [@today, @today]
      when 'week' then [@today.beginning_of_week, @today.end_of_week]
      when 'month' then [@today.beginning_of_month, @today.end_of_month]
      when 'custom' then custom_dates
      else add_error(:invalid_period)
      end
    end

    def custom_dates
      if @params[:start_date].blank? || @params[:end_date].blank?
        add_error(:incomplete_range)
        return
      end

      first = DateInputNormalizer.normalize(@params[:start_date])
      last = DateInputNormalizer.normalize(@params[:end_date])
      add_error(:invalid_start) unless first
      add_error(:invalid_end) unless last
      return if errors.any?

      add_error(:reversed_range) if first > last
      [first, last]
    end

    def add_error(key)
      errors << I18n.t("vendor_portal.transactions.filters.#{key}")
      nil
    end
  end
end
