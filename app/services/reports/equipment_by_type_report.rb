# frozen_string_literal: true

module Reports
  class EquipmentByTypeReport < BaseService
    PERIODS = %w[current_month current_quarter current_fy].freeze

    def initialize(period:, include_voucher_counts:, current_date: Date.current)
      super()
      @period = PERIODS.include?(period.to_s) ? period.to_s : 'current_fy'
      @include_voucher_counts = include_voucher_counts
      @current_date = current_date
    end

    def call
      non_voucher_counts = non_voucher_equipment_counts
      voucher_counts = include_voucher_counts ? voucher_equipment_counts : {}
      device_types = (non_voucher_counts.keys + voucher_counts.keys).uniq.sort

      rows = device_types.map do |device_type|
        {
          device_type: device_type,
          non_voucher_count: non_voucher_counts.fetch(device_type, 0),
          voucher_count: voucher_counts.fetch(device_type, 0)
        }
      end

      success(nil, {
                selected_period: period,
                period_options: period_options,
                period_label: period_label,
                rows: rows,
                chart_data: {
                  non_voucher: rows.to_h { |row| [row[:device_type], row[:non_voucher_count]] },
                  voucher: rows.to_h { |row| [row[:device_type], row[:voucher_count]] }
                }
              })
    rescue StandardError => e
      Rails.logger.error "Error generating equipment by type report: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      failure("Error generating equipment by type report: #{e.message}", empty_payload)
    end

    private

    attr_reader :period, :include_voucher_counts, :current_date

    def non_voucher_equipment_counts
      counts = Hash.new(0)
      Application.includes(evaluations: :recommended_products)
                 .where(fulfillment_type: :equipment, equipment_po_sent_at: report_range)
                 .find_each do |application|
        latest_completed_evaluation(application)&.recommended_products&.each do |product|
          add_device_type_counts(counts, product, 1)
        end
      end
      counts
    end

    def voucher_equipment_counts
      counts = Hash.new(0)
      VoucherTransaction.includes(voucher_transaction_products: :product)
                        .where(status: :transaction_completed,
                               transaction_type: :redemption,
                               processed_at: report_range)
                        .find_each do |transaction|
        transaction.voucher_transaction_products.each do |transaction_product|
          add_device_type_counts(counts, transaction_product.product, transaction_product.quantity)
        end
      end
      counts
    end

    def latest_completed_evaluation(application)
      application.evaluations.select(&:status_completed?).max_by do |evaluation|
        evaluation.evaluation_date || evaluation.updated_at
      end
    end

    def add_device_type_counts(counts, product, quantity)
      product.device_types.each do |device_type|
        counts[device_type] += quantity.to_i
      end
    end

    def report_range
      @report_range ||= date_range_for(period)
    end

    def date_range_for(period_name)
      case period_name
      when 'current_month'
        current_date.beginning_of_month.beginning_of_day..current_date.end_of_month.end_of_day
      when 'current_quarter'
        FiscalYear.quarter_start_date(current_date).beginning_of_day..
          FiscalYear.quarter_end_date(current_date).end_of_day
      else
        FiscalYear.time_range(
          FiscalYear.start_date_for(current_fiscal_year),
          FiscalYear.end_date_for(current_fiscal_year)
        )
      end
    end

    def period_label
      case period
      when 'current_month'
        current_date.strftime('%B %Y')
      when 'current_quarter'
        "Q#{FiscalYear.quarter_for(current_date)} #{FiscalYear.label_for_start_year(current_fiscal_year)}"
      else
        FiscalYear.label_for_start_year(current_fiscal_year)
      end
    end

    def period_options
      {
        'current_month' => current_date.strftime('%B %Y'),
        'current_quarter' => "Current Quarter (Q#{FiscalYear.quarter_for(current_date)})",
        'current_fy' => "Current Fiscal Year (#{FiscalYear.label_for_start_year(current_fiscal_year)})"
      }
    end

    def current_fiscal_year
      FiscalYear.current_start_year(on: current_date)
    end

    def empty_payload
      {
        selected_period: period,
        period_options: period_options,
        period_label: period_label,
        rows: [],
        chart_data: { non_voucher: {}, voucher: {} }
      }
    end

  end
end
