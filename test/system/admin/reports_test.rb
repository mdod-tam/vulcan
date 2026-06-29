# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ReportsTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      system_test_sign_in(@admin)
    end

    test 'reports page hides voucher report sections when vouchers are disabled' do
      FeatureFlag.disable!(:vouchers_enabled)

      visit admin_reports_path

      assert_selector 'h1', text: 'System Reports'
      assert_selector '#equipment-by-type-heading', text: 'Equipment by Type'
      assert_no_selector '#voucher-statistics-heading'
      assert_no_selector '#vendor-activity-heading'

      assert_selector reports_section_selector('equipment-by-type-heading'), text: 'Equipment by Type'
      assert_selector reports_section_selector('mfr-data-heading'), text: 'Managing for Results'
      take_full_page_screenshot('admin-reports-changed-sections-vouchers-off')
    end

    test 'reports page shows voucher report sections when vouchers are enabled' do
      FeatureFlag.enable!(:vouchers_enabled)

      visit admin_reports_path

      assert_selector 'h1', text: 'System Reports'
      assert_selector '#equipment-by-type-heading', text: 'Equipment by Type'
      assert_selector '#voucher-statistics-heading', text: 'Voucher Statistics'
      assert_selector '#vendor-activity-heading', text: 'Vendor Activity'

      assert_selector reports_section_selector('equipment-by-type-heading'), text: 'Equipment by Type'
      assert_selector reports_section_selector('voucher-statistics-heading'), text: 'Voucher Statistics'
      assert_selector reports_section_selector('vendor-activity-heading'), text: 'Vendor Activity'
      take_full_page_screenshot('admin-reports-changed-sections-vouchers-on')
    end

    private

    def reports_section_selector(heading_id)
      %(section[aria-labelledby="#{heading_id}"])
    end

    def take_full_page_screenshot(name)
      @screenshot_artifact_label = name.presence
      wait_for_meaningful_page_content(timeout: 3) if respond_to?(:wait_for_meaningful_page_content)

      increment_unique
      page.save_screenshot(image_path, full: true)
      write_screenshot_sidecar(image_path, label: @screenshot_artifact_label, html_saved: false)
      puts screenshot_log_message(image_path)
      image_path
    ensure
      @screenshot_artifact_label = nil
    end
  end
end
