# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  # Screenshot evidence for staff-visible secure link changes.
  class SecureLinkAdminEvidenceTest < ApplicationSystemTestCase
    include SystemTestEvidence

    setup do
      @admin = create(:admin)
      create(:admin, email: PublicAuditActor::SYSTEM_AUDIT_EMAIL) unless User.exists?(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
      system_test_sign_in(@admin)
    end

    test 'provider information panel and activity history after a replaced value' do
      application = create(:application, status: :awaiting_proof)
      form = create(:secure_request_form, application: application, recipient: application.user)
      Applications::SubmitProviderInfo.new(
        application: application,
        secure_request_form: form,
        params: {
          certifying_professional_name: application.certifying_professional_name,
          certifying_professional_phone: application.certifying_professional_phone,
          certifying_professional_email: 'replacement-provider@example.test'
        }
      ).call
      open_link = create(:secure_request_form, application: application, recipient: application.user)

      visit admin_application_path(application)

      assert_selector '#secure-request-forms-section [data-testid="provider-info-complete-note"]'
      assert_selector "#secure-request-forms-section button[aria-label*='Revoke link for']"
      find_by_id('secure-request-forms-section').scroll_to(:top)
      take_evidence_screenshot('admin-provider-info-panel-complete', full: true)
      assert_text 'Provider Info Replaced - Review'
      find_by_id('audit-logs').scroll_to(:top)
      take_evidence_screenshot('admin-provider-info-replaced-history', full: true)
      assert open_link.reload.active?
    end

    test 'certification section flags a kept-aside document and explains a disabled action' do
      application = create(:application, disability_certification_status: :approved, certifying_professional_name: 'Dr. Evidence')
      application.update_columns(certifying_professional_email: nil)
      application.additional_disability_certifications.attach(
        io: StringIO.new('late docuseal'),
        filename: 'late_docuseal.pdf',
        content_type: 'application/pdf',
        metadata: { source: 'docuseal', retention_reason: 'certification_approved' }
      )

      visit admin_application_path(application)

      assert_selector '[data-testid="additional-disability-certifications"]', text: 'received after approval, review'
      find('[data-testid="additional-disability-certifications"]').scroll_to(:center)
      take_evidence_screenshot('admin-certification-kept-aside', full: true)
    end

    test 'disabled secure certification action shows its reason' do
      application = create(:application, certifying_professional_name: 'Dr. Missing')
      application.update_columns(certifying_professional_email: nil, disability_certification_status: Application.disability_certification_statuses[:requested])

      visit admin_application_path(application)

      assert_selector '[data-testid="secure-cert-upload-disabled-reason"]'
      find('[data-testid="secure-cert-upload-disabled-reason"]').scroll_to(:center)
      take_evidence_screenshot('admin-certification-disabled-reason', full: true)
    end

    test 'vendor W9 history flags changed W9 details' do
      vendor = create(:vendor, :with_w9)
      vendor.update_column(:w9_status, Users::Vendor.w9_statuses[:approved])
      vendor.reload.update!(business_tax_id: '98-7654321', city: 'Annapolis')

      visit admin_vendor_path(vendor)

      assert_text 'W9 details changed after submission, review whether a new W9 is needed'
      assert_text 'Approved'
      take_evidence_screenshot('admin-vendor-w9-details-changed', full: true)
    end
  end
end
