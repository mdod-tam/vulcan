# frozen_string_literal: true

require 'test_helper'

class DocumentScansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:constituent)
    sign_in_as(@user)
  end

  test 'staging and recovery are account scoped and do not depend on the session' do
    post document_scans_path, params: { file: fixture_file_upload('income_proof.pdf', 'application/pdf'),
                                        purpose: 'proof', slot: 'income_proof', context: 'application:current' }
    assert_response :accepted
    scan = DocumentScan.find(response.parsed_body.fetch('id'))
    assert_nil response.parsed_body['signed_id']
    assert_empty scan.blob.attachments
    sign_in_as(@user)
    get document_scans_path, params: { purpose: 'proof', slot: 'income_proof', context: 'application:current' }
    assert_equal scan.id, response.parsed_body.fetch('id')
    scan.update!(status: :clean)
    get document_scan_path(scan)
    assert_equal scan.blob, ActiveStorage::Blob.find_signed!(response.parsed_body.fetch('signed_id'))
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
    sign_in_as(create(:constituent))
    get document_scan_path(scan)
    assert_response :not_found
  end

  test 'dismissed uploads are not restored and do not provide an intake receipt' do
    blob = scanned_upload(fixture_file_upload('income_proof.pdf', 'application/pdf'), user: @user)
    scan = DocumentScan.find_by!(blob: blob)
    delete document_scan_path(scan)
    assert_response :no_content
    get document_scan_path(scan)
    assert_nil response.parsed_body['signed_id']
    get document_scans_path, params: { purpose: 'proof', slot: 'income_proof' }
    assert_nil response.parsed_body
  end

  test 'fresh forms restore pending and clean scans but not blocked or failed scans' do
    blob = scanned_upload(fixture_file_upload('income_proof.pdf', 'application/pdf'), user: @user)
    scan = DocumentScan.find_by!(blob: blob)
    %w[pending clean blocked failed].each do |status|
      scan.update!(status: status)
      get document_scans_path, params: { purpose: 'proof', slot: 'income_proof' }
      assert_response :success
      if status.in?(%w[pending clean])
        assert_equal scan.id, response.parsed_body.fetch('id'), status
      else
        assert_nil response.parsed_body, status
      end

      get document_scan_path(scan)
      assert_response :success
      assert_equal status, response.parsed_body.fetch('status')
    end
  end

  test 'role limits purposes and default direct upload allocation is unavailable' do
    post document_scans_path, params: { purpose: 'w9', slot: 'w9_form' }
    assert_response :not_found
    post '/rails/active_storage/direct_uploads'
    assert_response :not_found
  end

  test 'canceling a pending upload invalidates its lease and future work' do
    post document_scans_path, params: { file: fixture_file_upload('income_proof.pdf', 'application/pdf'),
                                        purpose: 'proof', slot: 'income_proof' }
    scan = DocumentScan.find(response.parsed_body.fetch('id'))
    work = scan.claim_work!

    delete document_scan_path(scan)
    assert_response :no_content
    assert scan.reload.failed?
    assert_equal 'scan_canceled', scan.last_error_code
    assert_nil scan.lease_token
    assert_nil scan.next_attempt_at
    assert_not scan.begin_provider_work!(token: work.token)
    get document_scan_path(scan)
    assert_nil response.parsed_body['signed_id']
    get document_scans_path, params: { purpose: 'proof', slot: 'income_proof' }
    assert_nil response.parsed_body
  end

  test 'secure scans honor the form lifetime and cannot be accepted through another request' do
    application = create(:application, income_proof_required: true)
    token = SecureRequestForm.generate_public_token
    form = create(:secure_request_form, application: application, kind: :income_proof_resubmission,
                                        raw_token: token, expires_at: 20.minutes.from_now)
    post document_scans_path, params: { file: fixture_file_upload('income_proof.pdf', 'application/pdf'), purpose: 'proof',
                                        slot: 'income_proof', secure_form_type: 'proof', token: token }
    assert_response :accepted
    scan = DocumentScan.find(response.parsed_body.fetch('id'))
    assert_equal form, scan.secure_form
    assert_nil scan.user_id
    assert_not form.reload.submitted?
    travel 16.minutes do
      scan.update!(status: :clean)
      get document_scan_path(scan), params: { secure_form_type: 'proof', token: token }
      assert_response :success
      assert response.parsed_body['signed_id'].present?
      assert_not form.reload.submitted?
    end
    other_form = create(:secure_request_form, kind: :income_proof_resubmission, application: create(:application, income_proof_required: true))
    result = Applications::SubmitProofResubmission.new(application: other_form.application, secure_request_form: other_form,
                                                       file: scan.blob.signed_id).call
    assert_not result.success?
    assert_equal :unavailable, result.data.fetch(:errors).details.fetch(:file).first.fetch(:error)
    assert_not other_form.reload.submitted?
    travel 21.minutes do
      get document_scan_path(scan), params: { secure_form_type: 'proof', token: token }
      assert_response :not_found
      result = Applications::SubmitProofResubmission.new(application: application, secure_request_form: form, file: scan.blob.signed_id).call
      assert_not result.success?
      assert_not application.reload.income_proof.attached?
    end
  end

  test 'a secure scan stages only for the form type that names its kind' do
    proof_token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: create(:application, income_proof_required: true), kind: :income_proof_resubmission,
                                 raw_token: proof_token)
    certification_token = SecureRequestForm.generate_public_token
    certification_form = create(:certification_upload_form, raw_token: certification_token)

    [['proof', certification_token, 'income_proof', 'proof'], ['certification', proof_token, 'disability_certification', 'certification']].each do |type, token, slot, purpose|
      assert_no_difference 'DocumentScan.count' do
        post document_scans_path, params: { file: fixture_file_upload('income_proof.pdf', 'application/pdf'), purpose: purpose,
                                            slot: slot, secure_form_type: type, token: token }
      end
      assert_response :not_found, "#{type} scans must refuse another kind's token"
    end

    post document_scans_path, params: { file: fixture_file_upload('disability_certification_valid.pdf', 'application/pdf'),
                                        purpose: 'certification', slot: 'disability_certification',
                                        secure_form_type: 'certification', token: certification_token }
    assert_response :accepted
    assert_equal certification_form, DocumentScan.find(response.parsed_body.fetch('id')).secure_form
  end
end
