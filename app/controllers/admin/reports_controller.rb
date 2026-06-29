# frozen_string_literal: true

module Admin
  class ReportsController < Admin::BaseController
    include DashboardMetricsLoading

    def index
      @vouchers_enabled = FeatureFlag.enabled?(:vouchers_enabled)

      load_fiscal_year_data
      load_fiscal_year_application_counts
      load_fiscal_year_voucher_counts if @vouchers_enabled
      load_fiscal_year_service_counts
      load_vendor_data if @vouchers_enabled
      load_applications_chart_data
      load_vouchers_chart_data if @vouchers_enabled
      load_services_chart_data
      load_disability_type_data
      load_referral_source_data
      load_equipment_by_type_data
      load_mfr_reports_data
    end

    def show; end

    def equipment_distribution; end

    def evaluation_metrics; end

    def vendor_performance; end

    private

    def load_equipment_by_type_data
      result = Reports::EquipmentByTypeReport.new(
        period: params[:equipment_period],
        include_voucher_counts: @vouchers_enabled
      ).call

      payload = if result.is_a?(BaseService::Result) && result.success?
                  result.data
                else
                  {
                    selected_period: 'current_fy',
                    period_options: {},
                    period_label: '',
                    rows: [],
                    chart_data: { non_voucher: {}, voucher: {} }
                  }
                end

      @equipment_period = payload[:selected_period]
      @equipment_period_options = payload[:period_options]
      @equipment_period_label = payload[:period_label]
      @equipment_by_type_rows = payload[:rows]
      @equipment_by_type_chart_data = payload[:chart_data]
    end

    def load_mfr_reports_data
      result = Applications::ReportingService.new.generate_mfr_reports_data(
        include_voucher_metrics: @vouchers_enabled
      )
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
