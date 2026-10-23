# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class DocumentScanStatusTest < ApplicationSystemTestCase
    setup do
      ensure_system_audit_actor!
      system_test_sign_in(create(:admin))
    end

    test 'application documents show scan results separately from staff review at desktop and phone widths' do
      application = create(:application, medical_certification_status: :received)
      attach_cleared_proof(application, :income_proof, filename: 'income_proof.pdf')
      attach_lightweight_proof(application, :residency_proof, filename: 'residency_proof.pdf')
      attach_cleared_proof(application, :medical_certification, filename: 'medical_certification.pdf')

      visit admin_application_path(application)

      within('[aria-labelledby="attachments-title"]') do
        assert_selector '[data-scan-status="clean"]', text: /Virus scan\s+Passed/
        assert_selector '[data-scan-status="not_scanned"]', text: /Virus scan\s+Not scanned/
        assert_text 'Not Reviewed'
      end
      within('[data-testid="medical-certification"]') do
        assert_selector '[data-scan-status="clean"]', text: /Virus scan\s+Passed/
      end
      take_screenshot('admin-application-virus-scan-desktop', html: true, full: true)

      page.current_window.resize_to(390, 844)
      assert_selector '[data-scan-status="clean"]', text: /Virus scan\s+Passed/, count: 2
      take_screenshot('admin-application-virus-scan-phone', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'vendor and W9 review show the virus scan beside the document' do
      vendor = create(:vendor, :with_w9)
      visit admin_vendor_path(vendor)
      assert_selector '[data-scan-status="clean"]', text: /Virus scan\s+Passed/
      assert_text 'Pending Review'
      take_screenshot('admin-vendor-virus-scan', html: true, full: true)

      click_link 'Review W9'
      assert_selector '[data-scan-status="clean"]', text: /Virus scan\s+Passed/
      assert_button 'Approve'
      take_screenshot('admin-w9-review-virus-scan', html: true, full: true)
    end
  end
end
