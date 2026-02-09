# frozen_string_literal: true

module Admin
  class ReportsController < Admin::BaseController
    include DashboardMetricsLoading

    def index
      # Use the standardized metrics loading methods
      load_fiscal_year_data
      load_fiscal_year_application_counts
      load_fiscal_year_voucher_counts
      load_fiscal_year_service_counts
      load_vendor_data
      load_mfr_data
      load_chart_data
      load_disability_type_data
      load_referral_source_data
    end

    def show; end

    def equipment_distribution; end

    def evaluation_metrics; end

    def vendor_performance; end

    # All dashboard metrics loading is now handled by the DashboardMetricsLoading concern
  end
end
