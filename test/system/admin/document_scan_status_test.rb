# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class DocumentScanStatusTest < ApplicationSystemTestCase
    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      system_test_sign_in(@admin)
    end

    test 'certification recovery keeps another applications document out of the form' do
      application = create(:application, disability_certification_status: :requested)
      other_application = create(:application, disability_certification_status: :requested)
      visit admin_application_path(other_application)
      other_context = find('#disability-certification-upload-form [data-document-upload-context-value]')['data-document-upload-context-value']
      within '#disability-certification-upload-form' do
        attach_file 'Certification Document', Rails.root.join('test/fixtures/files/disability_certification_valid.pdf')
        assert_selector '[data-scan-state="pending"]'
      end
      scan = DocumentScan.where(user: @admin, purpose: 'certification', form_context: other_context).sole
      scan.update!(status: :clean, completed_at: Time.current)

      visit admin_application_path(application)
      within '#disability-certification-upload-form' do
        assert_equal "admin/applications:#{application.id}", find('[data-document-upload-context-value]')['data-document-upload-context-value']
        assert_no_selector 'input[type="hidden"][name="disability_certification"]', visible: :all
        assert_no_text 'Ready:'
        assert_field 'Certification Document', type: 'file'
      end
      take_screenshot('admin-certification-other-application-empty', html: true, full: true)

      visit admin_application_path(other_application)
      within '#disability-certification-upload-form' do
        assert_selector '[data-scan-state="clean"]', text: 'Ready:'
        receipt = find('input[type="hidden"][name="disability_certification"]', visible: :all).value
        assert_equal scan.blob, ActiveStorage::Blob.find_signed!(receipt)
      end
      take_screenshot('admin-certification-own-application-restored', html: true, full: true)
    end

    test 'application documents show scan results separately from staff review at desktop and phone widths' do
      application = create(:application, disability_certification_status: :received)
      attach_cleared_proof(application, :income_proof, filename: 'income_proof.pdf')
      attach_lightweight_proof(application, :residency_proof, filename: 'residency_proof.pdf')
      attach_cleared_proof(application, :disability_certification, filename: 'disability_certification.pdf')

      visit admin_application_path(application)

      within('[aria-labelledby="attachments-title"]') do
        assert_selector '[data-scan-status="clean"]', text: /Virus scan\s+Passed/
        assert_selector '[data-scan-status="not_scanned"]', text: /Virus scan\s+Not scanned/
        assert_text 'Not Reviewed'
      end
      within('[data-testid="disability-certification"]') do
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
