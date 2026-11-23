# frozen_string_literal: true

require 'test_helper'

module Admin
  class ReportsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin = create(:admin)
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
      FeatureFlag.disable!(:vouchers_enabled)
    end

    test 'all report pages are available to administrators and send no-store' do
      assert @admin.can_train?
      assert @admin.can_evaluate?
      report_paths.each do |path|
        get path
        assert_response :success
        assert_includes response.headers['Cache-Control'], 'no-store'
        assert_select 'meta[name="turbo-cache-control"][content="no-cache"]'
        assert_select 'nav[aria-label="Reports"] a[aria-current="page"]', count: 1
        assert_select 'a.skip-link[href="#main-content"]', text: 'Skip to reports'
        assert_select '#main-content[tabindex="-1"]'
      end
    end

    test 'unauthenticated visitors and non-admin staff cannot view any report' do
      sign_out
      report_paths.each do |path|
        get path
        assert_authentication_required
      end

      %i[trainer evaluator constituent vendor].each do |role|
        staff_member = create(role)
        create(:role_capability, user: staff_member, capability: 'can_evaluate') if role == :trainer
        create(:role_capability, user: staff_member, capability: 'can_train') if role == :evaluator
        sign_in_for_integration_test(staff_member, bypass_mfa_enrollment: true)
        report_paths.each do |path|
          get path
          assert_redirected_to root_path
          assert_no_match(/data-chart-config-value|Top staff contributions/, response.body)
        end
      end
    end

    test 'period is capped and falls back to twelve months' do
      get admin_reports_path(period: '3')
      assert_response :success
      chart = css_select('#review-backlog').first.parent.at_css('[data-chart-config-value]')
      assert_equal 3, JSON.parse(chart['data-chart-config-value']).dig('data', 'labels').size

      get admin_reports_path(period: { invalid: '999' })
      assert_response :success
      assert_select '#period option[selected][value="12"]'
    end

    test 'evaluations and training includes the fiscal-year service status breakdowns' do
      travel_to Time.zone.local(2026, 5, 1, 12, 0, 0) do
        create(:training_session, status: :requested, created_at: Time.zone.local(2025, 8, 1, 12, 0, 0))
        create(:training_session, :completed, created_at: Time.zone.local(2024, 8, 1, 12, 0, 0))
        create(:evaluation, status: :scheduled, created_at: Time.zone.local(2025, 8, 1, 12, 0, 0))
        create(:evaluation, status: :no_show, created_at: Time.zone.local(2024, 8, 1, 12, 0, 0))

        training_request = create_reviewed_application(user: create(:constituent))
        training_request.update!(training_requested_at: 1.hour.ago)
        evaluation_request = create_reviewed_application(user: create(:constituent))
        evaluation_request.update!(evaluation_requested_at: 1.hour.ago)

        get evaluation_metrics_admin_reports_path
        assert_response :success

        assert_select '#service-status-breakdown-heading', text: 'Sessions by status'
        assert_select 'caption', text: 'Training sessions by status'
        assert_select 'caption', text: 'Evaluation sessions by status'
        assert_select 'p', text: /Waiting now — 1 training request,\s+1 evaluation request\./

        training_table = css_select('caption').find { |caption| caption.text.strip == 'Training sessions by status' }.ancestors('table').first
        evaluation_table = css_select('caption').find { |caption| caption.text.strip == 'Evaluation sessions by status' }.ancestors('table').first

        assert_status_row training_table, 'Requested', current_fy: 1, previous_fy: 0
        assert_status_row training_table, 'Completed', current_fy: 0, previous_fy: 1
        assert_status_row evaluation_table, 'Scheduled', current_fy: 1, previous_fy: 0
        assert_status_row evaluation_table, 'No show', current_fy: 0, previous_fy: 1
      end
    end

    test 'empty views use one message and preserve monthly zeroes' do
      %w[appointments timing devices].each do |view|
        get evaluation_metrics_admin_reports_path(view:)
        assert_response :success
        assert_select '#main-content p', text: 'No results for these dates.', count: 1
        assert_select '#main-content p', text: 'No data for this period.', count: 0
      end

      get evaluation_metrics_admin_reports_path
      assert_select '#evaluation-appointments-completed-by-month + details tbody td', text: '0', count: 12

      create(:evaluation, :completed)
      get evaluation_metrics_admin_reports_path
      assert_select '#main-content p', text: 'No results for these dates.', count: 0
      assert_select '#training-hours-by-month + p', text: 'No activity for these dates.'
      assert_select '#training-hours-by-trainer + p', text: 'No data for this period.'
    end

    test 'vendor report mentions the order limit only when it leaves orders out' do
      application = create(:application, :approved, fulfillment_type: :equipment)
      product = create(:product)
      10.times do
        create(:equipment_item, application:, product:, purchase_order: create(:purchase_order, vendor_name: 'Harbor Supply'))
      end

      get vendor_performance_admin_reports_path
      assert_select 'section[aria-labelledby="oldest-orders-heading"] p', text: 'All dates.'
      assert_select 'section[aria-labelledby="oldest-orders-heading"] tbody tr', count: 10

      create(:equipment_item, application:, product:, purchase_order: create(:purchase_order, vendor_name: 'Harbor Supply'))
      get vendor_performance_admin_reports_path
      assert_select 'section[aria-labelledby="oldest-orders-heading"] p', text: 'All dates. Showing the 10 oldest.'
      assert_select 'section[aria-labelledby="oldest-orders-heading"] tbody tr', count: 10
    end

    test 'voucher statistics count vouchers by issued_at' do
      FeatureFlag.enable!(:vouchers_enabled)

      travel_to Time.zone.local(2026, 5, 1, 12, 0, 0) do
        application = create_reviewed_application(user: create(:constituent))
        create(:voucher,
               application: application,
               created_at: Time.zone.local(2024, 8, 1, 12, 0, 0),
               issued_at: Time.zone.local(2025, 8, 1, 12, 0, 0))

        get equipment_distribution_admin_reports_path
        assert_response :success
        assert_select '#voucher-statistics-heading tbody tr', text: /Vouchers issued\s+1\s+0/
      end
    end

    test 'voucher report sections follow the voucher flag' do
      get equipment_distribution_admin_reports_path
      assert_select '#voucher-statistics-heading', count: 0
      get vendor_performance_admin_reports_path
      assert_select '#vendor-activity-heading', count: 0

      FeatureFlag.enable!(:vouchers_enabled)
      get equipment_distribution_admin_reports_path
      assert_select '#voucher-statistics-heading summary', text: 'Fiscal year voucher totals'
      get vendor_performance_admin_reports_path
      assert_select '#vendor-activity-heading summary', text: 'Voucher vendor activity'
    end

    test 'vendor activity counts vendors with recorded transactions' do
      FeatureFlag.enable!(:vouchers_enabled)
      create(:voucher_transaction, vendor: create(:vendor, :approved))
      create(:voucher_transaction, vendor: create(:vendor, :approved), created_at: 2.months.ago)

      get vendor_performance_admin_reports_path
      assert_response :success
      assert_select '#vendor-activity-heading tr', text: /All time\s+2/
      assert_select '#vendor-activity-heading tr', text: /Past month\s+1/
    end

    test 'referral sources for the current fiscal quarter cover the whole calendar quarter' do
      travel_to Time.zone.local(2026, 6, 15, 12, 0, 0) do
        {
          'Before quarter' => Time.zone.local(2026, 3, 31, 23, 59, 59),
          'First day' => Time.zone.local(2026, 4, 1),
          'Last day' => Time.zone.local(2026, 6, 30, 23, 59, 59),
          'After quarter' => Time.zone.local(2026, 7, 1)
        }.each do |source, created_at|
          create(:application, user: create(:constituent, referral_source: source), created_at: created_at)
        end

        get admin_reports_path

        assert_response :success
        assert_select 'th', text: 'Q4 FY26'
        assert_equal({ 'First day' => 1, 'Last day' => 1 }, assigns(:report).referral_quarter_data)
      end
    end

    test 'equipment by type defaults to current fiscal year and counts actual outbound device shipments' do
      travel_to Time.zone.local(2026, 6, 15, 12, 0, 0) do
        tablet = create(:product, name: 'FY Tablet', device_types: ['Tablet'])
        phone = create(:product, name: 'FY Phone', device_types: ['Smartphone'])
        multi_type = create(:product, name: 'FY Combo', device_types: %w[Tablet Smartphone])

        create_shipped_equipment_application(product: multi_type, shipped_at: Time.zone.local(2026, 6, 10, 12, 0, 0))
        create_shipped_equipment_application(product: tablet, shipped_at: Time.zone.local(2026, 5, 10, 12, 0, 0))
        create_shipped_equipment_application(product: phone, shipped_at: Time.zone.local(2025, 8, 10, 12, 0, 0))

        get equipment_distribution_admin_reports_path
        assert_response :success

        assert_select '#equipment-period-heading', text: 'FY26'
        assert_equipment_row 'Tablet', non_voucher_count: 2
        assert_equipment_row 'Smartphone', non_voucher_count: 2
      end
    end

    test 'equipment by type filters current month and current fiscal quarter' do
      travel_to Time.zone.local(2026, 6, 15, 12, 0, 0) do
        tablet = create(:product, name: 'Quarter Tablet', device_types: ['Tablet'])
        phone = create(:product, name: 'Quarter Phone', device_types: ['Smartphone'])
        multi_type = create(:product, name: 'Quarter Combo', device_types: %w[Tablet Smartphone])

        create_shipped_equipment_application(product: multi_type, shipped_at: Time.zone.local(2026, 6, 10, 12, 0, 0))
        create_shipped_equipment_application(product: tablet, shipped_at: Time.zone.local(2026, 5, 10, 12, 0, 0))
        create_shipped_equipment_application(product: phone, shipped_at: Time.zone.local(2025, 8, 10, 12, 0, 0))

        get equipment_distribution_admin_reports_path(equipment_period: 'current_month')
        assert_response :success
        assert_select '#equipment-period-heading', text: 'June 2026'
        assert_equipment_row 'Tablet', non_voucher_count: 1
        assert_equipment_row 'Smartphone', non_voucher_count: 1

        get equipment_distribution_admin_reports_path(equipment_period: 'current_quarter')
        assert_response :success
        assert_select '#equipment-period-heading', text: 'Q4 FY26'
        assert_equipment_row 'Tablet', non_voucher_count: 2
        assert_equipment_row 'Smartphone', non_voucher_count: 1
      end
    end

    test 'equipment by type counts completed voucher redemption quantities when vouchers are enabled' do
      FeatureFlag.enable!(:vouchers_enabled)

      travel_to Time.zone.local(2026, 6, 15, 12, 0, 0) do
        product = create(:product, name: 'Voucher Tablet', device_types: ['Tablet'])
        application = create(:application, :approved, fulfillment_type: :voucher)
        voucher = create(:voucher, application: application)
        transaction = create(:voucher_transaction,
                             voucher: voucher,
                             vendor: create(:vendor),
                             processed_at: Time.zone.local(2026, 6, 10, 12, 0, 0),
                             status: :transaction_completed,
                             transaction_type: :redemption)
        VoucherTransactionProduct.create!(
          voucher_transaction: transaction,
          product: product,
          quantity: 3
        )

        get equipment_distribution_admin_reports_path(equipment_period: 'current_month')
        assert_response :success

        assert_equipment_row 'Tablet', non_voucher_count: 0, voucher_count: 3
      end
    end

    test 'equipment by type reports unavailable state instead of empty data on service failure' do
      Reports::EquipmentByTypeReport.any_instance.stubs(:call).returns(
        BaseService::Result.new(
          success: false,
          message: Reports::EquipmentByTypeReport::UNAVAILABLE_MESSAGE,
          data: {
            selected_period: 'current_fy',
            period_options: { 'current_fy' => 'Current Fiscal Year (FY26)' },
            period_label: 'FY26',
            rows: [],
            chart_data: { non_voucher: {}, voucher: {} },
            error_message: Reports::EquipmentByTypeReport::UNAVAILABLE_MESSAGE
          }
        )
      )

      get equipment_distribution_admin_reports_path
      assert_response :success

      equipment_section = css_select('#equipment-by-type-heading').first.ancestors('section').first
      assert_includes equipment_section.text, Reports::EquipmentByTypeReport::UNAVAILABLE_MESSAGE
      assert_no_match(/No equipment recorded for this period/, equipment_section.text)
    end

    test 'MFR hides vouchers when neither displayed fiscal year has any and allows fiscal year selection' do
      FeatureFlag.enable!(:vouchers_enabled)

      travel_to Time.zone.local(2026, 8, 1, 12) do
        get mfr_admin_reports_path(year: 2024)
        assert_response :success
        assert_select '#year option[selected]', text: 'FY25'
        assert_select '#report-title', text: 'Managing for Results (MFR)'
        assert_select '#mfr-data tbody tr', count: 3
        Reports::MfrReport::MEASURES.each_key { |measure| assert_select 'th', text: measure }
        assert_no_match(/Vouchers issued|Applications moved to approved/, response.body)

        chart = css_select('#mat-results-by-fiscal-year').first.parent.at_css('[data-chart-config-value]')
        assert_equal %w[FY25 FY24], JSON.parse(chart['data-chart-config-value']).dig('data', 'datasets').pluck('label')
      end
    end

    test 'MFR shows historical vouchers by issue date in the table and chart when vouchers are disabled' do
      travel_to Time.zone.local(2026, 8, 1, 12) do
        create(:voucher, :expired, issued_at: Time.zone.local(2023, 6, 30, 23, 59))
        create(:voucher, issued_at: Time.zone.local(2023, 7, 1))

        get mfr_admin_reports_path(year: 2022)
        assert_response :success
        assert_select '#year option[selected]', text: 'FY23'
        assert_select '#mfr-data tbody tr', text: /Vouchers issued\s+1\s+0/
        chart = css_select('#mat-results-by-fiscal-year').first.parent.at_css('[data-chart-config-value]')
        data = JSON.parse(chart['data-chart-config-value']).fetch('data')
        voucher_counts = data.fetch('datasets').map { |dataset| dataset.fetch('data').last }
        assert_equal 'Vouchers issued', data.fetch('labels').last
        assert_equal [1, 0], voucher_counts
      end
    end

    private

    def report_paths
      [admin_reports_path, evaluation_metrics_admin_reports_path, evaluation_metrics_admin_reports_path(view: 'timing'),
       evaluation_metrics_admin_reports_path(view: 'devices'), equipment_distribution_admin_reports_path,
       vendor_performance_admin_reports_path, mfr_admin_reports_path]
    end

    def assert_status_row(table, label, current_fy:, previous_fy:)
      row = table.css('tbody tr').find { |tr| tr.css('th').first.text.strip == label }
      assert_not_nil row, "expected service status row for #{label}"
      assert_equal current_fy.to_s, row.css('td')[0].text.strip
      assert_equal previous_fy.to_s, row.css('td')[1].text.strip
    end

    def assert_equipment_row(device_type, non_voucher_count:, voucher_count: nil)
      section = css_select('#equipment-by-type-heading').first.ancestors('section').first
      row = section.css('tbody tr').find { |tr| tr.css('th').first.text.strip == device_type }
      assert_not_nil row, "expected equipment row for #{device_type}"
      assert_equal non_voucher_count.to_s, row.css('td')[0].text.strip
      assert_equal voucher_count.to_s, row.css('td')[1].text.strip if voucher_count
    end

    def create_shipped_equipment_application(product:, shipped_at:)
      application = create_reviewed_application(user: create(:constituent))
      application.update!(fulfillment_type: :equipment)
      order = create(:purchase_order, number: "REPORT-#{application.id}", sent_at: shipped_at.to_date - 1.day)
      create(:equipment_item, application: application, product: product, purchase_order: order,
                              shipped_at: shipped_at.to_date, tracking_number: "REPORT-#{application.id}")
      application
    end

    def create_reviewed_application(user:)
      create(:application, :approved, :with_all_proofs, user: user)
    end
  end
end
