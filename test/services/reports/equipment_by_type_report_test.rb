# frozen_string_literal: true

require 'test_helper'

module Reports
  class EquipmentByTypeReportTest < ActiveSupport::TestCase
    setup do
      @product = create(:product, name: 'Quarter Tablet', device_types: ['Tablet'])
      @voucher = create(:voucher, application: create(:application, :approved, fulfillment_type: :voucher))
      @vendor = create(:vendor)
    end

    # Each quarter spans a daylight-saving change, so the endpoints sit in different UTC offsets.
    {
      'a quarter spanning spring daylight time' => [Date.new(2026, 3, 15), [2026, 1, 1], [2026, 3, 31], 'Q3 FY26'],
      'a quarter spanning fall daylight time' => [Date.new(2025, 11, 15), [2025, 10, 1], [2025, 12, 31], 'Q2 FY26'],
      'the first fiscal quarter' => [Date.new(2025, 8, 15), [2025, 7, 1], [2025, 9, 30], 'Q1 FY26'],
      'the last fiscal quarter in a leap year' => [Date.new(2024, 5, 29), [2024, 4, 1], [2024, 6, 30], 'Q4 FY24']
    }.each do |name, (reporting_date, (start_year, start_month, start_day), (end_year, end_month, end_day), label)|
      test "current_quarter covers #{name} through its last local instant" do
        first_instant = Time.zone.local(start_year, start_month, start_day)
        last_instant = Time.zone.local(end_year, end_month, end_day, 23, 59, 59, 999_999)
        # Distinct quantities make the total identify exactly which instants were counted.
        { first_instant - 1.second => 1, first_instant => 2, last_instant => 4, last_instant + 1.second => 8 }
          .each { |processed_at, quantity| redeem(processed_at, quantity) }

        result = report(reporting_date).call

        assert result.success?
        assert_equal label, result.data[:period_label]
        assert_equal 2 + 4, result.data[:rows].sole[:voucher_count]
      end
    end

    private

    def report(reporting_date)
      EquipmentByTypeReport.new(period: 'current_quarter', include_voucher_counts: true, current_date: reporting_date)
    end

    def redeem(processed_at, quantity)
      transaction = create(:voucher_transaction, voucher: @voucher, vendor: @vendor, processed_at: processed_at,
                                                 status: :transaction_completed, transaction_type: :redemption)
      VoucherTransactionProduct.create!(voucher_transaction: transaction, product: @product, quantity: quantity)
    end
  end
end
