# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ReportsTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
    end

    test 'admins navigate the separate reports and change periods with native charts' do
      FeatureFlag.disable!(:vouchers_enabled)
      create(:evaluation, :completed)
      create(:training_session, :completed)
      order = create(:purchase_order, vendor_name: 'Harbor Supply', sent_at: 12.days.ago.to_date)
      create(:equipment_item, purchase_order: order, shipped_at: 5.days.ago.to_date,
                              delivered_on: 3.days.ago.to_date, tracking_number: 'REPORTING-TEST')
      create(:equipment_item, purchase_order: order)
      older_year = FiscalYear.current_start_year - 3
      create(:voucher, issued_at: FiscalYear.start_date_for(older_year).beginning_of_day)

      visit admin_reports_path
      assert_chart 'review-backlog'
      assert_selector '#report-title', text: 'Applications'
      page.driver.browser.keyboard.type(:Tab)
      assert_selector 'a.skip-link:focus', text: 'Skip to reports'
      page.driver.browser.keyboard.type(:Enter)
      assert_selector '#main-content:focus'
      within 'section:has(> #review-backlog)' do
        assert_no_selector 'section[aria-labelledby="review-backlog"]'
        assert_selector 'canvas[aria-hidden="true"]'
        find('summary', text: 'View data').execute_script('this.focus()')
        page.driver.browser.keyboard.type(:Enter)
        assert_selector 'details[open] table'
        assert_selector 'th[scope="col"]', text: 'Month'
        assert_selector 'tbody th[scope="row"]'
      end
      select 'Past 3 months', from: 'Period'
      click_button 'Apply report period'
      assert_current_path admin_reports_path(period: 3)
      assert_chart 'review-backlog'
      take_screenshot('admin-reports-applications', full: true)

      report_link 'Evaluations and training'
      assert_chart 'evaluation-appointments-completed-by-month'
      assert_chart 'training-hours-by-trainer'
      click_link 'Reports and scheduling'
      assert_chart 'evaluation-reports-submitted-by-month-and-evaluator'
      click_link 'Devices'
      assert_chart 'products-recommended-by-evaluator'
      take_screenshot('admin-reports-service-devices', full: true)

      report_link 'Equipment orders'
      assert_chart 'units-with-shipment-recorded-by-month'
      assert_chart 'equipment-by-type-heading'
      assert_selector '#equipment-by-type-heading', text: 'Equipment by type'
      assert_button 'Apply equipment period'
      assert_no_selector '#voucher-statistics-heading'

      report_link 'Vendor performance'
      assert_chart 'shipment-volume-versus-speed'
      assert_chart 'ordered-units-by-vendor'
      assert_no_selector '#vendor-activity-heading'
      take_screenshot('admin-reports-vendor-performance', full: true)
      page.current_window.resize_to(390, 844)
      within 'section[aria-labelledby="vendor-shipping-times-heading"]' do
        scroll_area = find('[tabindex="0"]')
        scroll_area.execute_script('this.focus()')
        page.driver.browser.keyboard.type(:Right)
        assert_selector '[tabindex="0"]:focus' do |element|
          element.evaluate_script('this.scrollLeft').positive?
        end
      end
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('admin-reports-vendor-keyboard-scroll', full: true, html: true)
      page.current_window.resize_to(1200, 800)

      report_link 'MFR reports', heading: 'Managing for Results (MFR)'
      assert_chart 'mat-results-by-fiscal-year'
      assert_no_selector 'section:has(> #mat-results-by-fiscal-year) summary'
      within '#mfr-data' do
        assert_selector 'tbody tr', count: 3
      end
      year = first('#year option').value.to_i - 1
      find(%(#year option[value="#{year}"])).select_option
      click_button 'Apply fiscal year'
      assert_current_path mfr_admin_reports_path(year:)
      assert_chart 'mat-results-by-fiscal-year'
      within '#mfr-data' do
        assert_selector 'tbody tr', count: 4
        assert_text(/Vouchers issued\s+0\s+1/)
      end
      take_screenshot('admin-reports-mfr', full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'voucher totals stay on the equipment and vendor pages when vouchers are enabled' do
      FeatureFlag.enable!(:vouchers_enabled)

      visit evaluation_metrics_admin_reports_path(view: 'devices')
      assert_text 'No results for these dates.', count: 1
      take_screenshot('admin-reports-empty-devices', html: true)

      visit equipment_distribution_admin_reports_path
      assert_selector '#voucher-statistics-heading summary', text: 'Fiscal year voucher totals'
      assert_no_selector '#vendor-activity-heading'

      report_link 'Vendor performance'
      assert_selector '#vendor-activity-heading summary', text: 'Voucher vendor activity'
    end

    private

    def report_link(label, heading: label)
      within('nav[aria-label="Reports"]') { click_link label }
      assert_selector '#report-title', text: heading
    end

    def assert_chart(heading_id)
      assert_selector "section:has(h3##{heading_id}) canvas[width][height]"
    end
  end
end
