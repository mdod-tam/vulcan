# frozen_string_literal: true

module Admin
  class ReportsController < Admin::BaseController
    include DashboardMetricsLoading

    def index
      load_fiscal_year_data
      load_fiscal_year_application_counts
      load_fiscal_year_voucher_counts
      load_fiscal_year_service_counts
      load_vendor_data
      load_chart_data
      load_disability_type_data
      load_referral_source_data
      load_mfr_reports_data
    end

    def show; end

    def equipment_distribution; end

    def evaluation_metrics; end

    def vendor_performance; end

    private

    def load_mfr_reports_data
      result = Applications::ReportingService.new.generate_mfr_reports_data
      unless result.is_a?(BaseService::Result) && result.success?
        @mfr_most_recent = empty_mfr_fy_payload
        @mfr_preceding = empty_mfr_fy_payload
        @mfr_chart_data = { current: {}, previous: {} }
        return
      end

      @mfr_most_recent = result.data[:most_recent_fy]
      @mfr_preceding = result.data[:preceding_fy]
      @mfr_chart_data = result.data[:mfr_chart_data]
    end

    def empty_mfr_fy_payload
      {
        fy_label: '',
        fy_period_label: '',
        summary: {},
        chart_data: {}
      }
    end
  end
end
