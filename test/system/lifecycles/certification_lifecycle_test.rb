# frozen_string_literal: true

require 'application_system_test_case'

class CertificationLifecycleTest < ApplicationSystemTestCase
  test 'staff request a certification, reject an incomplete response, and approve the replacement' do
    FeatureFlag.disable!(:dcf_auto_request_certification)
    admin = create(:admin)
    applicant = create(:constituent)
    application = create(:application, user: applicant,
                                       certifying_professional_name: 'Dr. Jane Smith',
                                       certifying_professional_email: 'drsmith@example.com',
                                       certifying_professional_phone: '555-555-5555')
    reason = RejectionReason.find_or_create_by!(code: 'missing_signature', proof_type: 'disability_certification', locale: 'en') do |row|
      row.body = 'The disability certification is missing the required signature.'
    end

    system_test_sign_in(admin, bypass_mfa_enrollment: true)
    visit admin_application_path(application)
    assert_text 'Dr. Jane Smith'
    assert_text '555-555-5555'
    assert_difference('application.certification_upload_forms.count', 1) do
      accept_confirm { click_button 'Send Secure Cert Upload Link' }
      assert_text I18n.t('admin.applications.certification_upload_requests.create.success')
    end
    assert_equal 'requested', application.reload.disability_certification_status

    system_test_switch_user(applicant)
    visit constituent_portal_application_path(application)
    assert_text 'Dr. Jane Smith'
    assert_selector '[role="status"]', text: 'Requested'

    system_test_switch_user(admin, bypass_mfa_enrollment: true)
    visit admin_application_path(application)
    assert_selector '[data-testid="disability-certification-upload-form"]', text: 'Upload Disability Certification'
    assert_no_text 'View Disability Certification Document'
    assert_no_button 'Review Disability Certification'

    within '[data-testid="disability-certification-upload-form"]' do
      choose 'Approve Certification and Upload'
      click_button 'Process Certification'
    end
    assert_error_message('Please select a file to upload')
    assert_equal 'requested', application.reload.disability_certification_status

    within '[data-testid="disability-certification-upload-form"]' do
      choose 'Reject Certification'
      reason_field = find('select[name="rejection_reason_code"]')
      click_button 'Process Certification'
      assert_equal false, reason_field.evaluate_script('this.validity.valid')
      assert_current_path admin_application_path(application)
      assert_equal 'requested', application.reload.disability_certification_status
      select 'Other (custom reason)', from: 'rejection_reason_code'
      assert_selector '#cert-custom-reason-area', visible: true
      assert_field 'disability_certification_rejection_reason', disabled: false
      assert_selector 'label[for="disability_certification_rejection_reason"]', text: 'Custom Rejection Reason'
      select 'Missing Signature', from: 'rejection_reason_code'
      click_button 'Process Certification'
    end
    assert_text 'Disability certification rejected.'
    assert_equal 'rejected', application.reload.disability_certification_status
    assert_equal reason.body, application.disability_certification_rejection_reason
    assert_audit_event('disability_certification_status_changed', actor: admin, auditable: application)

    within '[data-testid="disability-certification-upload-form"]' do
      choose 'Approve Certification and Upload'
      attach_cleared_document 'disability_certification', file_fixture('disability_certification_valid.pdf')
      click_button 'Process Certification'
    end
    assert_success_message('Disability certification successfully uploaded and approved.')
    assert_equal 'approved', application.reload.disability_certification_status
    assert application.disability_certification.attached?
    assert_no_selector '[data-testid="disability-certification-upload-form"]'
    assert_link 'View Disability Certification Document'
    assert_audit_event('disability_certification_status_changed', actor: admin, auditable: application)
    assert_empty page.evaluate_script('window.__systemTestErrors')
    take_screenshot('certification-lifecycle-approved', full: true, html: true)
  end
end
