# frozen_string_literal: true

require 'test_helper'

class PaperApplicationDirectUploadTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    # Use factory bot instead of fixture
    @admin = create(:admin)
    sign_in_for_integration_test(@admin)

    # Set up FPL policies for income threshold validation
    setup_fpl_policies
  end

  test 'direct upload for paper applications should work with signed_ids' do
    # Set up sample proof files using existing fixtures in test/fixtures/files/
    income_proof = fixture_file_upload('income_proof.pdf', 'application/pdf')
    residency_proof = fixture_file_upload('residency_proof.pdf', 'application/pdf')

    # Create blobs using direct upload
    income_blob = create_direct_upload_blob(income_proof)
    residency_blob = create_direct_upload_blob(residency_proof)

    # Verify blobs were created
    assert_not_nil income_blob.signed_id
    assert_not_nil residency_blob.signed_id

    # Submit paper application with signed_ids
    assert_difference('Application.count') do
      post admin_paper_applications_path, params: {
        constituent: {
          first_name: 'Test',
          last_name: 'User', date_of_birth: '01/15/1980',
          email: 'test@example.com',
          phone: '555-555-5555',
          physical_address_1: '123 Main St',
          city: 'Anytown',
          state: 'MD',
          zip_code: '12345',
          hearing_disability: true
        },
        application: {
          household_size: 2,
          annual_income: 20_000,
          maryland_resident: true,
          self_certify_disability: true,
          medical_provider_name: 'Dr. Smith',
          medical_provider_phone: '555-123-4567',
          medical_provider_email: 'smith@example.com',
          terms_accepted: true,
          information_verified: true,
          medical_release_authorized: true
        },
        income_proof_action: 'accept',
        income_proof_signed_id: income_blob.signed_id,
        residency_proof_action: 'accept',
        residency_proof_signed_id: residency_blob.signed_id
      }
    end

    # Check for successful redirects
    assert_redirected_to admin_application_path(Application.last)

    # Verify attachment was successful
    application = Application.last
    assert application.income_proof.attached?
    assert application.residency_proof.attached?

    # Verify statuses were set correctly
    assert_equal 'approved', application.income_proof_status
    assert_equal 'approved', application.residency_proof_status
  end

  private

  def create_direct_upload_blob(file)
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: file.original_filename,
      byte_size: file.size,
      checksum: OpenSSL::Digest::MD5.file(file.path).base64digest,
      content_type: file.content_type
    )

    # Simulate the direct upload by directly attaching content to the blob
    File.open(file.path) do |io|
      blob.upload(io)
    end

    blob
  end

  # Use the sign_in helper from test_helper.rb rather than defining our own
  # This ensures consistency with other tests
end
