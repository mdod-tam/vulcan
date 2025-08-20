# frozen_string_literal: true

require 'test_helper'

module Applications
  class DependentEmailHandlingTest < ActiveSupport::TestCase
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      # Set up FPL policies for income validation
      setup_fpl_policies

      @admin = create(:admin)
      @guardian = create(:constituent, email: 'guardian@example.com')
    end

    test 'creates dependent using guardian email when email_strategy is guardian' do
      # Create parameters for a paper application with email_strategy set to 'guardian'
      service = PaperApplicationService.new(
        params: {
          applicant_type: 'dependent',
          guardian_id: @guardian.id,
          email_strategy: 'guardian', # Use guardian's email
          phone_strategy: 'guardian', # Use guardian's phone
          relationship_type: 'Parent',
          constituent: {
            first_name: 'Dependent',
            last_name: 'User',
            date_of_birth: '2015-01-01',
            hearing_disability: '1' # Ensure at least one disability
            # NOTE: dependent_email intentionally omitted since strategy is 'guardian'
          },
          application: {
            household_size: 2,
            annual_income: 18_000, # Safely under the threshold
            maryland_resident: true,
            medical_provider_name: 'Dr. Test',
            medical_provider_phone: '555-123-4567',
            medical_provider_email: 'doctor@example.com',
            self_certify_disability: true
          },
          income_proof_action: 'accept',
          income_proof: fixture_file_upload('test/fixtures/files/income_proof.pdf', 'application/pdf'),
          residency_proof_action: 'accept',
          residency_proof: fixture_file_upload('test/fixtures/files/residency_proof.pdf', 'application/pdf')
        },
        admin: @admin
      )

      # Mock just enough for proof upload
      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ProofAttachmentService.stubs(:reject_proof_without_attachment).returns({ success: true })

      assert service.create, "Paper application creation failed: #{service.errors.join('; ')}"

      # Verify the dependent was created
      dependent = service.constituent
      assert_not_nil dependent, 'Dependent should have been created'

      # Key assertions: The dependent should have a system email but the guardian's email in dependent_email
      assert_match(/dependent-.*@system\.matvulcan\.local/, dependent.email,
                   'Dependent should have a system-generated email to avoid uniqueness conflicts')
      assert_equal @guardian.email, dependent.dependent_email,
                   "Dependent should have guardian's email in dependent_email field when email_strategy is 'guardian'"
      assert_equal @guardian.email, dependent.effective_email,
                   'Dependent effective_email should return guardian email'
    end

    test 'creates dependent with their own email when email_strategy is dependent' do
      dependent_email = "dependent_#{Time.now.to_i}@example.com"

      # Create parameters for a paper application with email_strategy set to 'dependent'
      service = PaperApplicationService.new(
        params: {
          applicant_type: 'dependent',
          guardian_id: @guardian.id,
          email_strategy: 'dependent', # Use dependent's own email
          phone_strategy: 'dependent', # Use dependent's own phone
          relationship_type: 'Parent',
          constituent: {
            first_name: 'Dependent',
            last_name: 'User',
            date_of_birth: '2015-01-01',
            dependent_email: dependent_email, # Providing a distinct email for the dependent
            hearing_disability: '1' # Ensure at least one disability
          },
          application: {
            household_size: 2,
            annual_income: 18_000, # Safely under the threshold
            maryland_resident: true,
            medical_provider_name: 'Dr. Test',
            medical_provider_phone: '555-123-4567',
            medical_provider_email: 'doctor@example.com',
            self_certify_disability: true
          },
          income_proof_action: 'accept',
          income_proof: fixture_file_upload('test/fixtures/files/income_proof.pdf', 'application/pdf'),
          residency_proof_action: 'accept',
          residency_proof: fixture_file_upload('test/fixtures/files/residency_proof.pdf', 'application/pdf')
        },
        admin: @admin
      )

      # Mock proof uploads
      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ProofAttachmentService.stubs(:reject_proof_without_attachment).returns({ success: true })

      assert service.create, "Paper application creation failed: #{service.errors.join('; ')}"

      # Verify the dependent was created with their own email
      dependent = service.constituent
      assert_not_nil dependent, 'Dependent should have been created'
      assert_equal dependent_email, dependent.email,
                   'Dependent should keep their own email when provided'
      assert_equal dependent_email, dependent.dependent_email,
                   'Dependent should have their own email in dependent_email field'
      assert_equal dependent_email, dependent.effective_email,
                   'Dependent effective_email should return their own email'
    end
  end
end
