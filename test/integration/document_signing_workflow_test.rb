# frozen_string_literal: true

require 'test_helper'

class DocumentSigningWorkflowTest < ActionDispatch::IntegrationTest
  include AuthenticationTestHelper

  setup do
    @admin = create(:admin)
    sign_in_for_integration_test(@admin)

    # Webhook audit events require a system actor.
    @system_user = create(:admin, email: 'system@example.com')
    User.stubs(:system_user).returns(@system_user)

    @application = create(:application, :in_progress,
                          application_date: Date.current,
                          medical_provider_email: 'doctor@example.com',
                          medical_provider_name: 'Dr. Jane Smith')

    @mock_submission = {
      'id' => 'sub_123456',
      'submitters' => [
        {
          'id' => 'submitter_789',
          'email' => 'doctor@example.com'
        }
      ]
    }

    @webhook_secret = 'test_webhook_secret'
    Rails.application.credentials.stubs(:webhook_secret).returns(@webhook_secret)
  end

  test 'complete document signing workflow from request to completion' do
    # Signing request
    DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

    assert_difference -> { @application.reload.document_signing_request_count }, 1 do
      post send_document_signing_request_admin_application_path(@application)
      assert_redirected_to admin_application_path(@application)
    end

    @application.reload
    assert_equal 'docuseal', @application.document_signing_service
    assert_equal 'sub_123456', @application.document_signing_submission_id
    assert_equal 'sent', @application.document_signing_status
    assert_equal 'requested', @application.medical_certification_status

    # Viewed webhook
    viewed_payload = {
      event_type: 'form.viewed',
      data: {
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com'
      }
    }

    signature = compute_webhook_signature(viewed_payload.to_json)
    post webhooks_docuseal_medical_certification_path,
         params: viewed_payload,
         headers: { 'X-Webhook-Signature' => signature },
         as: :json

    assert_response :ok
    @application.reload
    assert_equal 'opened', @application.document_signing_status

    # Started webhook
    started_payload = {
      event_type: 'form.started',
      data: {
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com'
      }
    }

    signature = compute_webhook_signature(started_payload.to_json)
    post webhooks_docuseal_medical_certification_path,
         params: started_payload,
         headers: { 'X-Webhook-Signature' => signature },
         as: :json

    assert_response :ok
    # The started webhook records an event without a status change.

    # Completed webhook
    completed_payload = {
      event_type: 'form.completed',
      data: {
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com',
        'documents' => [
          {
            'url' => 'https://example.com/signed_doc.pdf',
            'filename' => 'medical_cert.pdf'
          }
        ],
        'audit_log_url' => 'https://example.com/audit_log'
      }
    }

    mock_response = mock('http_response')
    mock_response.stubs(:status).returns(mock('status'))
    mock_response.status.stubs(:success?).returns(true)
    mock_response.stubs(:body).returns('mock pdf content')
    HTTP.stubs(:timeout).returns(HTTP)
    HTTP.stubs(:get).returns(mock_response)

    signature = compute_webhook_signature(completed_payload.to_json)
    post webhooks_docuseal_medical_certification_path,
         params: completed_payload,
         headers: { 'X-Webhook-Signature' => signature },
         as: :json

    assert_response :ok
    @application.reload
    assert_equal 'signed', @application.document_signing_status
    assert_equal 'received', @application.medical_certification_status
    assert_not_nil @application.document_signing_signed_at
    assert @application.medical_certification.attached?
    assert_equal 'https://example.com/audit_log', @application.document_signing_audit_url

    # Review queue
    get admin_applications_path(filter: 'digitally_signed_needs_review')
    assert_response :success
    assert_match @application.user.full_name, response.body

    # Audit events
    assert_equal 1, Event.where(action: 'document_signing_request_sent', auditable: @application).count
    assert_equal 1, Event.where(action: 'document_signing_viewed', auditable: @application).count
    assert_equal 1, Event.where(action: 'document_signing_started', auditable: @application).count
    assert_equal 1, Event.where(action: 'document_signing_completed', auditable: @application).count
  end

  test 'document signing workflow with provider declining' do
    DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

    post send_document_signing_request_admin_application_path(@application)
    @application.reload

    declined_payload = {
      event_type: 'form.declined',
      data: {
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com'
      }
    }

    signature = compute_webhook_signature(declined_payload.to_json)
    post webhooks_docuseal_medical_certification_path,
         params: declined_payload,
         headers: { 'X-Webhook-Signature' => signature },
         as: :json

    assert_response :ok
    @application.reload
    assert_equal 'declined', @application.document_signing_status

    # The service rejects requests sent within 30 seconds.
    @application.update!(document_signing_requested_at: 31.seconds.ago)
    assert_difference -> { @application.reload.document_signing_request_count }, 1 do
      post send_document_signing_request_admin_application_path(@application)
    end
  end

  test 'document signing workflow with resubmission after rejection' do
    # Set up the rejected certification and replacement submission.
    @application.update!(medical_certification_status: :rejected)
    ApplicationStatusChange.create!(application: @application, user: @admin, from_status: 'received', to_status: 'rejected',
                                    change_type: 'medical_certification', changed_at: 2.days.ago)
    @application.update!(
      document_signing_service: 'docuseal',
      document_signing_submission_id: 'sub_123456',
      document_signing_status: :sent,
      document_signing_requested_at: 1.day.ago
    )

    completed_payload = {
      event_type: 'form.completed',
      data: {
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com',
        'documents' => [
          {
            'url' => 'https://example.com/signed_doc.pdf',
            'filename' => 'medical_cert.pdf'
          }
        ],
        'audit_log_url' => 'https://example.com/audit_log'
      }
    }

    mock_response = mock('http_response')
    mock_response.stubs(:status).returns(mock('status'))
    mock_response.status.stubs(:success?).returns(true)
    mock_response.stubs(:body).returns('mock pdf content')
    HTTP.stubs(:timeout).returns(HTTP)
    HTTP.stubs(:get).returns(mock_response)

    signature = compute_webhook_signature(completed_payload.to_json)
    post webhooks_docuseal_medical_certification_path,
         params: completed_payload,
         headers: { 'X-Webhook-Signature' => signature },
         as: :json

    assert_response :ok
    @application.reload

    assert_equal 'received', @application.medical_certification_status
    assert_equal 'signed', @application.document_signing_status
    assert @application.medical_certification.attached?
  end

  test 'document signing workflow ignores completion when already approved' do
    @application.update!(medical_certification_status: :approved)
    @application.update!(
      document_signing_service: 'docuseal',
      document_signing_submission_id: 'sub_123456',
      document_signing_status: :sent
    )

    completed_payload = {
      event_type: 'form.completed',
      data: {
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com',
        'documents' => [
          {
            'url' => 'https://example.com/signed_doc.pdf'
          }
        ],
        'audit_log_url' => 'https://example.com/audit_log'
      }
    }

    signature = compute_webhook_signature(completed_payload.to_json)
    post webhooks_docuseal_medical_certification_path,
         params: completed_payload,
         headers: { 'X-Webhook-Signature' => signature },
         as: :json

    assert_response :ok
    @application.reload

    assert_equal 'approved', @application.medical_certification_status
    assert_equal 'signed', @application.document_signing_status
    assert_not @application.medical_certification.attached?
  end

  test 'prevents rapid duplicate requests' do
    @application.update!(
      document_signing_requested_at: 15.seconds.ago,
      document_signing_request_count: 1
    )

    post send_document_signing_request_admin_application_path(@application)

    assert_redirected_to admin_application_path(@application)
    follow_redirect!
    assert_match(/Request sent too recently/, flash[:alert])

    @application.reload
    assert_equal 1, @application.document_signing_request_count
  end

  private

  def compute_webhook_signature(payload)
    OpenSSL::HMAC.hexdigest('SHA256', @webhook_secret, payload)
  end
end
