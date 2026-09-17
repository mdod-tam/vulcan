# frozen_string_literal: true

require 'test_helper'

module Applications
  class PaperApplicationAttachmentTest < ActiveSupport::TestCase
    include PaperIdentityConfirmationHelper

    include ActionDispatch::TestProcess::FixtureFile

    setup do
      @admin = create(:admin)
      @timestamp = Time.current.to_f.to_s.gsub('.', '')

      # Set Current context to skip proof validations in tests
      Current.paper_context = true
      @income_proof = fixture_file_upload('test/fixtures/files/income_proof.pdf', 'application/pdf')
      @residency_proof = fixture_file_upload('test/fixtures/files/residency_proof.pdf', 'application/pdf')
    end

    test 'can attach proofs using ActiveStorage::Blob signed_id' do
      income_blob, residency_blob = create_blobs
      params = direct_upload_params(income_blob.signed_id, residency_blob.signed_id)
      mock_policy

      # Verify we have valid blobs
      assert income_blob.persisted?, 'Income blob not persisted'
      assert residency_blob.persisted?, 'Residency blob not persisted'
      assert_not_nil income_blob.signed_id, 'Income blob missing signed_id'
      assert_not_nil residency_blob.signed_id, 'Residency blob missing signed_id'

      # Mock ProofAttachmentService for testing
      ProofAttachmentService.expects(:attach_proof).with(
        has_entries(
          proof_type: :income,
          status: :approved,
          submission_method: :paper
        )
      ).returns({ success: true })

      ProofAttachmentService.expects(:attach_proof).with(
        has_entries(
          proof_type: :residency,
          status: :approved,
          submission_method: :paper
        )
      ).returns({ success: true })

      service = PaperApplicationService.new(params: confirmed_paper_params(params, admin: @admin), admin: @admin)
      assert service.create, "Paper application creation failed with errors: #{service.errors.join(', ')}"
    end

    test 'a signed GlobalID is not accepted as an Active Storage upload reference' do
      income_blob, residency_blob = create_blobs
      params = direct_upload_params(income_blob.to_signed_global_id.to_s, residency_blob.to_signed_global_id.to_s)
      mock_policy
      service = PaperApplicationService.new(params: confirmed_paper_params(params, admin: @admin), admin: @admin)

      assert_no_difference ['User.count', 'Application.count', 'ActiveStorage::Attachment.count'] do
        assert_not service.create
      end
      assert_match(/no longer available/, service.errors.join(' '))
    end

    private

    def create_blobs
      income_blob = ActiveStorage::Blob.create_and_upload!(
        io: @income_proof.open,
        filename: @income_proof.original_filename,
        content_type: @income_proof.content_type
      )
      residency_blob = ActiveStorage::Blob.create_and_upload!(
        io: @residency_proof.open,
        filename: @residency_proof.original_filename,
        content_type: @residency_proof.content_type
      )
      [income_blob, residency_blob]
    end

    def direct_upload_params(income_blob_signed_id, residency_blob_signed_id)
      {
        constituent: {
          first_name: 'Jane',
          last_name: 'Doe',
          email: "jane.doe.#{@timestamp}@example.com",
          phone: "301555#{@timestamp[-4..]}",
          physical_address_1: '123 Main St',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          cognition_disability: '1'
        },
        application: {
          household_size: 1,
          annual_income: '18000',
          maryland_resident: true,
          self_certify_disability: true,
          medical_provider_name: 'Dr. Smith',
          medical_provider_phone: '301-555-1313',
          medical_provider_email: 'dr.smith@example.com'
        },
        income_proof_action: 'accept',
        income_proof: income_blob_signed_id,
        residency_proof_action: 'accept',
        residency_proof: residency_blob_signed_id
      }
    end

    def mock_policy
      # Allow both string and symbol variations since the code might use either
      Policy.stubs(:get).with(any_of(:fpl_1_person, 'fpl_1_person')).returns('20000')
      Policy.stubs(:get).with(any_of(:fpl_modifier_percentage, 'fpl_modifier_percentage')).returns('200')
      Policy.stubs(:get).with('support_email').returns('mat.program1@maryland.gov')
    end

    teardown do
      # Clean up Current context after the test
      Current.reset
    end
  end
end
