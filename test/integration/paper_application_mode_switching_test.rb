# frozen_string_literal: true

require 'test_helper'

class PaperApplicationModeSwitchingTest < ActionDispatch::IntegrationTest
  include ProofResubmissionTestHelper

  setup do
    @admin = create(:admin)
    sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)

    Policy.find_or_create_by!(key: 'fpl_2_person') { |policy| policy.value = '21150' }
    Policy.find_or_create_by!(key: 'fpl_modifier_percentage') { |policy| policy.value = '400' }

    @raw_income = fixture_file_upload('test/fixtures/files/income_proof.pdf', 'application/pdf')
    @raw_residency = fixture_file_upload('test/fixtures/files/residency_proof.pdf', 'application/pdf')
    @income_proof_file = scanned_upload(@raw_income, user: @admin, purpose: :proof, slot: 'income_proof').signed_id
    @residency_proof_file = scanned_upload(@raw_residency, user: @admin, purpose: :proof, slot: 'residency_proof')
  end

  teardown do
    @raw_income.tempfile.close
    @raw_residency.tempfile.close
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
      last_name: 'Applicant', date_of_birth: '01/15/1980',
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
      certifying_professional_name: 'Dr. Smith',
      certifying_professional_phone: '555-123-4567',
      certifying_professional_fax: '555-123-4568',
      certifying_professional_email: 'dr.smith@example.com',
      terms_accepted: true,
      information_verified: true,
      disability_information_release_authorized: true
    }
  end

  test 'accepted paper income stays current while rejected residency can be replaced and approved' do
    review_started_at = Time.current
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

    income_blob_id = application.income_proof.blob.id
    income_review = application.proof_reviews.proof_type_income.status_approved.sole
    assert_equal @admin, income_review.admin
    assert_equal income_blob_id, income_review.reviewed_blob_id
    assert income_review.submission_method_paper?
    assert_operator income_review.reviewed_at, :>=, review_started_at
    assert_operator income_review.reviewed_at, :<=, Time.current
    original_review = income_review.attributes
    original_state = application.reload.attributes.slice('status', 'income_proof_status', 'residency_proof_status', 'total_rejections')

    # A current approval cannot be decided again without another submission.
    assert_no_difference ['ProofReview.count', 'ApplicationStatusChange.count', 'Event.count', 'ActiveStorage::Attachment.count'] do
      patch update_proof_status_admin_application_path(application), params: {
        **proof_decision_params(application, :income),
        proof_type: 'income',
        status: 'rejected',
        rejection_reason: 'expired',
        rejection_notes: 'Documentation is expired'
      }
    end
    assert_response :unprocessable_content
    assert_includes response.body, 'Proof is not reviewable for this application'
    assert_equal original_state, application.reload.attributes.slice(*original_state.keys)
    assert_equal original_review, income_review.reload.attributes
    assert_equal income_blob_id, application.income_proof.blob.id

    # A newly received replacement is pending until staff review it.
    attached = ProofAttachmentService.attach_proof(
      application: application, proof_type: :residency, blob_or_file: @residency_proof_file,
      status: :not_reviewed, admin: @admin, submission_method: :paper
    )
    assert attached[:success], attached[:error]&.message
    application.reload
    assert_equal 'not_reviewed', application.residency_proof_status

    patch update_proof_status_admin_application_path(application), params: {
      **proof_decision_params(application, :residency),
      proof_type: 'residency',
      status: 'approved'
    }

    assert_response :redirect
    application.reload

    assert_equal income_blob_id, application.income_proof.blob.id
    assert_equal 'approved', application.income_proof_status
    assert_equal original_review, application.proof_reviews.proof_type_income.sole.attributes

    assert application.residency_proof.attached?, 'Residency proof should be attached after approval'
    assert_equal 'approved', application.residency_proof_status

    assert_equal %w[rejected approved], application.proof_reviews.proof_type_residency.chronological.pluck(:status)
    residency_review = application.proof_reviews.proof_type_residency.status_approved.sole
    assert_equal @admin, residency_review.admin
    assert_equal @residency_proof_file.id, residency_review.reviewed_blob_id
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
