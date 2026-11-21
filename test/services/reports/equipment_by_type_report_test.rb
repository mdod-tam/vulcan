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

    test 'distribution uses outbound dates across direct purchased stock and no-PO existing stock' do
      reporting_date = Date.current
      application = create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment)
      old_order = create(:purchase_order, sent_at: 1.year.ago.to_date)
      create(:equipment_item, application:, product: @product, purchase_order: old_order, shipped_at: reporting_date, tracking_number: 'DIRECT')
      existing = create(:equipment_item, application:, product: @product, purchase_order: nil, fulfillment_source: 'existing_stock',
                                         stock_received_on: 1.year.ago.to_date, intake_provenance: 'Verified stock',
                                         stock_allocated_at: 1.day.ago, setup_confirmed_at: Time.current,
                                         shipped_at: reporting_date, tracking_number: 'EXISTING')
      stock_order = create(:purchase_order, purpose: 'program_stock', sent_at: 1.year.ago.to_date)
      group = BidGroup.create!(number: 'REPORT-STOCK', purpose: 'program_stock', purchase_order: stock_order)
      line = group.bid_group_lines.create!(product: @product, quantity: 1)
      create(:equipment_item, application:, product: @product, purchase_order: stock_order, acquisition_bid_group_line: line,
                              fulfillment_source: 'program_stock_po', stock_received_on: 1.year.ago.to_date,
                              stock_allocated_at: 1.day.ago, setup_confirmed_at: Time.current,
                              shipped_at: reporting_date, tracking_number: 'PURCHASED-STOCK')
      create(:equipment_item, application:, product: @product, purchase_order: old_order)
      create(:equipment_item, application: nil, product: @product, purchase_order: nil, fulfillment_source: 'existing_stock',
                              stock_received_on: reporting_date, intake_provenance: 'Unallocated verified stock')
      create(:equipment_item, application:, product: @product, purchase_order: old_order,
                              shipped_at: reporting_date.beginning_of_month - 1.day, tracking_number: 'PREVIOUS-MONTH')

      result = EquipmentByTypeReport.new(period: 'current_month', include_voucher_counts: false, current_date: reporting_date).call
      assert result.success?
      assert_equal 3, result.data[:rows].sole[:non_voucher_count]
      assert_nil existing.purchase_order_id
    end

    test 'equipment shipped on July first appears only in the new fiscal year' do
      first_day = Date.new(2024, 7, 1)
      last_day = Date.new(2025, 6, 30)
      application = create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment)
      order = create(:purchase_order, sent_at: first_day.prev_day)
      [first_day.prev_day, first_day, last_day, last_day.next_day].each_with_index do |date, index|
        create(:equipment_item, application: application, product: @product, purchase_order: order,
                                shipped_at: date, tracking_number: "FY-BOUNDARY-#{index}")
      end

      closing_year = EquipmentByTypeReport.new(period: 'current_fy', include_voucher_counts: false, current_date: last_day).call
      opening_year = EquipmentByTypeReport.new(period: 'current_fy', include_voucher_counts: false, current_date: last_day.next_day).call

      assert closing_year.success?
      assert opening_year.success?
      assert_equal 2, closing_year.data[:rows].sole[:non_voucher_count]
      assert_equal 1, opening_year.data[:rows].sole[:non_voucher_count]
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
