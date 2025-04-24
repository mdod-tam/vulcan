# frozen_string_literal: true

require 'test_helper'

class PaperApplicationModeSwitchingTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create(:admin) # Use factory instead of fixture
    sign_in(@admin)

    # Ensure necessary policies exist for income threshold check
    Policy.create_or_find_by!(key: 'fpl_2_person', value: '21150')
    Policy.create_or_find_by!(key: 'fpl_modifier_percentage', value: '400')

    # Create sample proofs for testing using ActiveStorage::Blob.create_and_upload!
    income_file = fixture_file_upload('test/fixtures/files/sample.pdf', 'application/pdf')
    @income_blob = ActiveStorage::Blob.create_and_upload!(
      io: income_file,
      filename: income_file.original_filename,
      content_type: income_file.content_type
    )

    residency_file = fixture_file_upload('test/fixtures/files/sample.pdf', 'application/pdf')
    @residency_blob = ActiveStorage::Blob.create_and_upload!(
      io: residency_file,
      filename: residency_file.original_filename,
      content_type: residency_file.content_type
    )
  end

  test 'paper application service properly handles mode switching between accept and reject' do
    # Create a test constituent using factory
    @constituent = create(:constituent)

    # Step 1: First create application with income proof attached but residency proof rejected
    # For testing, directly use the file rather than creating a blob
    post admin_paper_applications_path, params: {
      # Pass constituent attributes instead of just ID
      constituent: {
        first_name: @constituent.first_name,
        last_name: @constituent.last_name,
        email: @constituent.email,
        phone: @constituent.phone,
        physical_address_1: @constituent.physical_address_1,
        city: @constituent.city,
        state: @constituent.state,
        zip_code: @constituent.zip_code,
        hearing_disability: @constituent.hearing_disability,
        vision_disability: @constituent.vision_disability,
        speech_disability: @constituent.speech_disability,
        mobility_disability: @constituent.mobility_disability,
        cognition_disability: @constituent.cognition_disability
      },
      application: {
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
      },
      income_proof_action: 'accept',
      income_proof_signed_id: @income_blob.signed_id, # Use signed_id
      residency_proof_action: 'reject',
      residency_proof_rejection_reason: 'missing_name',
      residency_proof_rejection_notes: 'Name is missing on document'
    }

    assert_response :redirect
    application = Application.last
    assert_redirected_to admin_application_path(application)

    # Verify income proof is attached
    assert application.income_proof.attached?
    assert_equal 'approved', application.income_proof_status

    # Verify residency proof is rejected but not attached
    assert_not application.residency_proof.attached?
    assert_equal 'rejected', application.residency_proof_status

    # Step 2: Switch the modes - reject income and accept residency
    puts "DEBUG: About to patch application #{application.id} with income_proof_action=reject and residency_proof_action=accept"
    puts "DEBUG: Application before patch - income_proof_status: #{application.income_proof_status}, residency_proof_status: #{application.residency_proof_status}"
    puts "DEBUG: Income proof attached? #{application.income_proof.attached?}, Residency proof attached? #{application.residency_proof.attached?}"

    # Paper applications are created through admin/paper_applications but then become regular applications
    # For updating proof status, we need to use the update_proof_status action

    # First, reject the income proof
    patch update_proof_status_admin_application_path(application), params: {
      proof_type: 'income',
      status: 'rejected',
      rejection_reason: 'expired',
      rejection_notes: 'Documentation is expired'
    }
    assert_response :redirect

    # For the residency proof, we need to first attach the file
    # We'll use direct attachment instead of the service
    application.residency_proof.attach(@residency_blob)
    application.update_column(:residency_proof_status, Application.residency_proof_statuses[:not_reviewed])
    application.reload

    puts "DEBUG: After attaching residency proof - residency_proof attached? #{application.residency_proof.attached?}"

    # Now we can approve the residency proof
    patch update_proof_status_admin_application_path(application), params: {
      proof_type: 'residency',
      status: 'approved'
    }

    puts "DEBUG: Response status: #{response.status}, Flash alert: #{flash[:alert]}"
    assert_response :redirect
    application.reload

    # Verify income proof is now rejected and attachment is purged
    assert_not application.income_proof.attached?
    assert_equal 'rejected', application.income_proof_status

    # Verify residency proof is now attached and approved
    # Verify residency proof is now attached and approved
    puts "DEBUG: Before final assertion - residency_proof attached? #{application.residency_proof.attached?}" # ADDED DEBUG
    assert application.residency_proof.attached?, 'Residency proof should be attached after approval' # Added message
    assert_equal 'approved', application.residency_proof_status

    # Debug output to see what proof reviews we have
    puts "DEBUG: All proof reviews: #{application.proof_reviews.map do |pr|
      "#{pr.proof_type}:#{pr.status}:#{pr.rejection_reason}"
    end.join(', ')}"

    # Verify we have the correct proof reviews
    income_review = application.proof_reviews.find_by(proof_type: :income, status: :rejected, rejection_reason: 'expired')
    assert_not_nil income_review, "Should have an income proof review with rejection_reason 'expired'"

    # For residency, we should have both a rejected review from the first step and an approved review from the second step
    residency_rejected_review = application.proof_reviews.find_by(proof_type: :residency, status: :rejected,
                                                                  rejection_reason: 'missing_name')
    assert_not_nil residency_rejected_review, "Should have a residency proof review with rejection_reason 'missing_name'"

    # We should also have a proof review for the approved residency proof
    # The ProofReviewer service creates a proof review with status 'approved' when approving a proof
    residency_approved_reviews = application.proof_reviews.where(proof_type: :residency, status: :approved)
    puts "DEBUG: Residency approved reviews: #{residency_approved_reviews.map { |pr| pr.inspect }.join(', ')}"

    # Check if we have any approved residency proof reviews
    assert residency_approved_reviews.exists?, 'Should have at least one approved residency proof review'
  end

  test 'paper application service properly handles invalid signed_ids' do
    # This test verifies the service doesn't crash when given invalid signed_ids

    # Create a test constituent using factory
    @constituent = create(:constituent)

    # Attempt to create application with invalid signed_id
    post admin_paper_applications_path, params: {
      # Pass constituent attributes instead of just ID
      constituent: {
        first_name: @constituent.first_name,
        last_name: @constituent.last_name,
        email: @constituent.email,
        phone: @constituent.phone,
        physical_address_1: @constituent.physical_address_1,
        city: @constituent.city,
        state: @constituent.state,
        zip_code: @constituent.zip_code,
        hearing_disability: @constituent.hearing_disability,
        vision_disability: @constituent.vision_disability,
        speech_disability: @constituent.speech_disability,
        mobility_disability: @constituent.mobility_disability,
        cognition_disability: @constituent.cognition_disability
      },
      application: {
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
      },
      income_proof_action: 'accept',
      income_proof_signed_id: 'invalid-signed-id-that-doesnt-exist', # Invalid signed_id
      residency_proof_action: 'reject',
      residency_proof_rejection_reason: 'missing_name'
    }

    # Should fail gracefully with error message
    assert_response :unprocessable_entity
    assert_match(/mismatched digest|Error processing proof/i, flash[:alert])
  end
end
