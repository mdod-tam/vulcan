# frozen_string_literal: true

require 'application_system_test_case'

class ApplicationLifecycleTest < ApplicationSystemTestCase
  test 'rejected proof is replaced before the application advances through confirmed approvals' do
    FeatureFlag.disable!(:vouchers_enabled)
    FeatureFlag.disable!(:dcf_auto_request_certification)
    admin = create(:admin)
    applicant = create(:constituent)
    application = create(:application, user: applicant, skip_proofs: true)
    %i[income_proof residency_proof id_proof disability_certification].each do |attachment|
      attach_cleared_proof(application, attachment, filename: "#{attachment}.png")
    end
    application.update!(disability_certification_status: :received)

    system_test_sign_in(admin, bypass_mfa_enrollment: true)
    visit admin_application_path(application)
    assert_no_selector '[data-testid="disability-certification-upload-form"]'
    assert_link 'View Disability Certification Document'
    click_review_proof_and_wait('income')
    assert_body_not_scrollable
    within('#incomeProofReviewModal') { click_button 'Close' }
    assert_no_selector '#incomeProofReviewModal[open]'
    assert_body_scrollable
    open_proof_rejection_modal('income')
    submit_custom_proof_rejection('The income document is unreadable.')
    assert_no_selector '#proofRejectionModal[open]'
    assert_equal 'rejected', application.reload.income_proof_status
    assert_equal 'The income document is unreadable.', application.proof_reviews.recent.first.rejection_reason

    system_test_switch_user(applicant)
    visit constituent_portal_application_path(application)
    click_on 'Resubmit Income Proof'
    assert_selector 'h1', text: 'Upload New Income Proof'
    assert_text 'Maximum file size: 5MB'
    attach_cleared_document 'income_proof', file_fixture('income_proof.pdf')
    click_button 'Submit Document'
    assert_success_message('Proof submitted successfully')
    assert_current_path constituent_portal_application_path(application)
    assert_equal 'not_reviewed', application.reload.income_proof_status

    system_test_switch_user(admin, bypass_mfa_enrollment: true)
    visit admin_application_path(application)
    [
      ['incomeProofReviewModal', :income_proof_status, 'Approve income proof?'],
      ['residencyProofReviewModal', :residency_proof_status, 'Approve residency proof?'],
      ['idProofReviewModal', :id_proof_status, 'Approve ID proof?'],
      ['disabilityCertificationReviewModal', :disability_certification_status, 'Approve this disability certification?']
    ].each do |modal, status_field, message|
      find("button[data-modal-id='#{modal}']").click
      assert_selector "dialog##{modal}[open]"
      assert_body_not_scrollable
      before = application.reload.public_send(status_field)
      assert_equal(message, dismiss_confirm { within("##{modal}") { click_button 'Approve' } })
      assert_equal before, application.reload.public_send(status_field), "canceling #{status_field} must preserve its status"
      assert_selector "dialog##{modal}[open]"

      assert_equal(message, accept_confirm { within("##{modal}") { click_button 'Approve' } })
      assert_no_selector "dialog##{modal}[open]"
      assert_body_scrollable
      assert_equal 'approved', application.reload.public_send(status_field), status_field.to_s
    end

    assert_equal 'approved', application.reload.status
    assert_link 'View Disability Certification Document'
    assert_no_selector '[data-testid="disability-certification-upload-form"]'
    assert_empty page.evaluate_script('window.__systemTestErrors')
    take_screenshot('application-lifecycle-approved', full: true, html: true)
  end
end
