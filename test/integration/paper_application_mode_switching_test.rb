# frozen_string_literal: true

require 'test_helper'

class PaperApplicationModeSwitchingTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create(:admin)
    sign_in_for_integration_test(@admin)

    Policy.find_or_create_by!(key: 'fpl_2_person') { |policy| policy.value = '21150' }
    Policy.find_or_create_by!(key: 'fpl_modifier_percentage') { |policy| policy.value = '400' }

    @income_proof_file = fixture_file_upload('test/fixtures/files/income_proof.pdf', 'application/pdf')
    @residency_proof_file = fixture_file_upload('test/fixtures/files/residency_proof.pdf', 'application/pdf')
  end

  def unique_paper_contact
    suffix = SecureRandom.hex(4)
    {
      email: "paper-app-test-#{suffix}@example.com",
      phone: "410-555-#{SecureRandom.random_number(9000) + 1000}"
    }
  end

  def paper_self_applicant_params(contact = unique_paper_contact)
    {
      first_name: 'Paper',
      last_name: 'Applicant',
      email: contact[:email],
      phone: contact[:phone],
      physical_address_1: '123 Test St',
      city: 'Baltimore',
      state: 'MD',
      zip_code: '21201',
      hearing_disability: '1',
      vision_disability: '0',
      speech_disability: '0',
      mobility_disability: '0',
      cognition_disability: '0'
    }
  end

  def paper_application_params
    {
      household_size: 2,
      annual_income: 20_000,
      maryland_resident: true,
      self_certify_disability: true,
      medical_provider_name: 'Dr. Smith',
      medical_provider_phone: '555-123-4567',
      medical_provider_fax: '555-123-4568',
      medical_provider_email: 'dr.smith@example.com',
      terms_accepted: true,
      information_verified: true,
      medical_release_authorized: true
    }
  end

  test 'paper application service properly handles mode switching between accept and reject' do
    # Initial proof decisions
    post admin_paper_applications_path, params: {
      constituent: paper_self_applicant_params,
      application: paper_application_params,
      income_proof_action: 'accept',
      income_proof: @income_proof_file,
      residency_proof_action: 'reject',
      residency_proof_rejection_reason: 'missing_name'
    }

    assert_response :redirect
    application = Application.last
    assert_redirected_to admin_application_path(application)

    assert application.income_proof.attached?
    assert_equal 'approved', application.income_proof_status

    assert_not application.residency_proof.attached?
    assert_equal 'rejected', application.residency_proof_status

    # Review updates use the regular application endpoint after paper creation.

    patch update_proof_status_admin_application_path(application), params: {
      proof_type: 'income',
      status: 'rejected',
      rejection_reason: 'expired',
      rejection_notes: 'Documentation is expired'
    }
    assert_response :redirect

    # Approval requires an attachment. Attach residency proof before the review.
    application.residency_proof.attach(@residency_proof_file)
    application.update_column(:residency_proof_status, Application.residency_proof_statuses[:not_reviewed])
    application.reload

    patch update_proof_status_admin_application_path(application), params: {
      proof_type: 'residency',
      status: 'approved'
    }

    assert_response :redirect
    application.reload

    assert_not application.income_proof.attached?
    assert_equal 'rejected', application.income_proof_status

    assert application.residency_proof.attached?, 'Residency proof should be attached after approval'
    assert_equal 'approved', application.residency_proof_status

    income_review = application.proof_reviews.find_by(proof_type: :income, status: :rejected, rejection_reason: 'expired')
    assert_not_nil income_review, "Should have an income proof review with rejection_reason 'expired'"

    # ProofReviewer creates the approval record.
    residency_approved_reviews = application.proof_reviews.where(proof_type: :residency, status: :approved)

    assert residency_approved_reviews.exists?, 'Should have at least one approved residency proof review'
  end

  test 'paper application service properly handles invalid signed_ids' do
    contact = unique_paper_contact

    assert_no_difference ['User.count', 'Application.count', 'Event.count', 'ActiveStorage::Attachment.count'] do
      post admin_paper_applications_path, params: {
        constituent: paper_self_applicant_params(contact),
        application: paper_application_params,
        income_proof_action: 'accept',
        income_proof_signed_id: 'invalid-signed-id-that-doesnt-exist',
        residency_proof_action: 'reject',
        residency_proof_rejection_reason: 'missing_name'
      }
    end

    # Refused input must not leave partial records.
    assert_response :unprocessable_content
    assert_select '[role=alert]', text: "Income proof: #{I18n.t('documents.refused.unavailable')}"
    assert_nil User.find_by(email: contact[:email])
  end
end
