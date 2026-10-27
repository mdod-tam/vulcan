# frozen_string_literal: true

require 'test_helper'

class PaperApplicationScannedUploadTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = create(:admin)
    sign_in_for_integration_test(@admin)

    setup_fpl_policies
  end

  test 'paper intake accepts cleared uploads through retained signed IDs' do
    income_proof = fixture_file_upload('income_proof.pdf', 'application/pdf')
    residency_proof = fixture_file_upload('residency_proof.pdf', 'application/pdf')

    income_blob = scanned_upload(income_proof, user: @admin, slot: 'income_proof')
    residency_blob = scanned_upload(residency_proof, user: @admin, slot: 'residency_proof')

    assert_not_nil income_blob.signed_id
    assert_not_nil residency_blob.signed_id

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

    assert_redirected_to admin_application_path(Application.last)

    application = Application.last
    assert application.income_proof.attached?
    assert application.residency_proof.attached?

    assert_equal 'approved', application.income_proof_status
    assert_equal 'approved', application.residency_proof_status
  end
end
