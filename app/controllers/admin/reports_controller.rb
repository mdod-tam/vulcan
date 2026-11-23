# frozen_string_literal: true

module Admin
  class ReportsController < Admin::BaseController
    SERVICE_VIEWS = %w[appointments timing devices].freeze

    before_action :no_store
    before_action :set_period, except: :mfr

    def index
      @activity = Reports::ApplicationActivity.new(@period)
      @report = Reports::FiscalYearReport.new
    end

    def evaluation_metrics
      @service_view = SERVICE_VIEWS.find { |view| view == params[:view] } || SERVICE_VIEWS.first
      @metrics = Reports::ServiceActivity.new(@period).public_send(@service_view)
      @report = Reports::FiscalYearReport.new if @service_view == 'appointments'
    end

    def equipment_distribution
      @activity = Reports::EquipmentActivity.new(@period)
      @vouchers_enabled = FeatureFlag.enabled?(:vouchers_enabled)
      @report = Reports::FiscalYearReport.new
      @equipment_by_type = Reports::EquipmentByTypeReport.new(
        period: params[:equipment_period], include_voucher_counts: @vouchers_enabled
      ).call.data
    end

    def vendor_performance
      @activity = Reports::EquipmentActivity.new(@period)
      @report = Reports::FiscalYearReport.new if FeatureFlag.enabled?(:vouchers_enabled)
    end

    def mfr
      @mfr = Reports::MfrReport.new(params[:year])
      @measures = @mfr.comparison_rows
    end

    private

    def set_period
      @period = Reports::Period.new(params[:period])
    end
  end
end
