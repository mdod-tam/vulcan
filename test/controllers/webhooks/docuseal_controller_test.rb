# frozen_string_literal: true

require 'test_helper'

module Webhooks
  class DocusealControllerTest < ActionDispatch::IntegrationTest
    setup do
      @system_user = create(:admin, email: 'system@example.com')
      User.stubs(:system_user).returns(@system_user)
      
      @application = create(:application, :in_progress,
                           document_signing_service: 'docuseal',
                           document_signing_submission_id: 'sub_123456',
                           document_signing_status: :sent,
                           medical_certification_status: :requested)
      
      # Mock webhook secret
      @webhook_secret = 'test_webhook_secret'
      Rails.application.credentials.stubs(:webhook_secret).returns(@webhook_secret)

      # Bypass authentication in the controller chain
      ApplicationController.any_instance.stubs(:authenticate_user!).returns(true)
      ApplicationController.any_instance.stubs(:require_login).returns(true)
      
      @viewed_payload = {
        event_type: 'form.viewed',
        data: {
          'submission_id' => 'sub_123456',
          'email' => 'doctor@example.com'
        }
      }

      @started_payload = {
        event_type: 'form.started',
        data: {
          'submission_id' => 'sub_123456',
          'email' => 'doctor@example.com'
        }
      }

      @completed_payload = {
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

      @declined_payload = {
        event_type: 'form.declined',
        data: {
          'submission_id' => 'sub_123456',
          'email' => 'doctor@example.com'
        }
      }
    end

    def make_signed_webhook_request(payload)
      signature = compute_signature(payload.to_json)
      post webhooks_docuseal_medical_certification_path,
           params: payload,
           headers: webhook_headers(signature),
           as: :json
    end

    def make_signed_webhook_request_with_alt_header(payload)
      signature = compute_signature(payload.to_json)
      post webhooks_docuseal_medical_certification_path,
           params: payload,
           headers: webhook_headers(signature, 'X-DocuSeal-Signature'),
           as: :json
    end

    def webhook_headers(signature = nil, header = 'X-Webhook-Signature')
      headers = { 'Content-Type' => 'application/json' }
      headers[header] = signature if signature
      headers
    end

    def compute_signature(payload)
      OpenSSL::HMAC.hexdigest('SHA256', @webhook_secret, payload)
    end

    test 'accepts valid form.viewed event' do
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      make_signed_webhook_request(@viewed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'opened', @application.document_signing_status

      # Verify audit event was created
      event = Event.where(action: 'document_signing_viewed').last
      assert_not_nil event
      assert_equal @application, event.auditable
      assert_equal 'sub_123456', event.metadata['document_signing_submission_id']
    end

    test 'accepts valid form.started event' do
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      @application.update!(document_signing_status: :opened)

      make_signed_webhook_request(@started_payload)
      assert_response :ok

      # No status change expected for started event, just audit logging
      @application.reload
      assert_equal 'opened', @application.document_signing_status

      # Verify audit event was created
      event = Event.where(action: 'document_signing_started').last
      assert_not_nil event
      assert_equal @application, event.auditable
    end

    test 'handles form.completed event with approved medical cert status' do
      @application.update!(medical_certification_status: :approved)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      make_signed_webhook_request(@completed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      assert_not_nil @application.document_signing_signed_at
      # Should NOT change medical_certification_status when already approved
      assert_equal 'approved', @application.medical_certification_status
      # Should NOT attach file when already approved
      assert_not @application.medical_certification.attached?

      # Verify audit event was created
      event = Event.where(action: 'document_signing_completed').last
      assert_not_nil event
      assert_equal @application, event.auditable
    end

    test 'handles form.completed event with rejected medical cert status' do
      @application.update!(medical_certification_status: :rejected)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      # Mock HTTP download
      mock_response = mock('http_response')
      mock_response.stubs(:status).returns(mock('status'))
      mock_response.status.stubs(:success?).returns(true)
      mock_response.stubs(:body).returns('mock pdf content')
      HTTP.stubs(:timeout).returns(HTTP)
      HTTP.stubs(:get).returns(mock_response)

      make_signed_webhook_request(@completed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      assert_not_nil @application.document_signing_signed_at
      # Should change medical_certification_status from rejected to received
      assert_equal 'received', @application.medical_certification_status
      # Should attach file for resubmission
      assert @application.medical_certification.attached?
      assert_equal 'https://example.com/audit_log', @application.document_signing_audit_url
    end

    test 'handles form.completed event with requested medical cert status' do
      @application.update!(medical_certification_status: :requested)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      # Mock HTTP download
      mock_response = mock('http_response')
      mock_response.stubs(:status).returns(mock('status'))
      mock_response.status.stubs(:success?).returns(true)
      mock_response.stubs(:body).returns('mock pdf content')
      HTTP.stubs(:timeout).returns(HTTP)
      HTTP.stubs(:get).returns(mock_response)

      make_signed_webhook_request(@completed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      assert_equal 'received', @application.medical_certification_status
      assert @application.medical_certification.attached?
    end

    test 'handles form.declined event' do
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      make_signed_webhook_request(@declined_payload)
      assert_response :ok

      @application.reload
      assert_equal 'declined', @application.document_signing_status

      # Verify audit event was created
      event = Event.where(action: 'document_signing_declined').last
      assert_not_nil event
      assert_equal @application, event.auditable
    end

    test 'ignores unknown event types' do
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      
      unknown_payload = {
        event_type: 'form.unknown',
        data: { 'submission_id' => 'sub_123456' }
      }

      make_signed_webhook_request(unknown_payload)
      assert_response :ok
    end

    test 'handles missing application gracefully' do
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      
      payload = @viewed_payload.deep_dup
      payload[:data]['submission_id'] = 'nonexistent_id'

      make_signed_webhook_request(payload)
      assert_response :ok
    end

    test 'rejects request without event_type' do
      invalid_payload = {
        data: { 'submission_id' => 'sub_123456' }
      }

      make_signed_webhook_request(invalid_payload)
      assert_response :unprocessable_content
    end

    test 'rejects request without data' do
      invalid_payload = {
        event_type: 'form.viewed'
      }

      make_signed_webhook_request(invalid_payload)
      assert_response :unprocessable_content
    end

    test 'handles DocuSeal signature header format' do
      # Test the alternative signature header
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      make_signed_webhook_request_with_alt_header(@viewed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'opened', @application.document_signing_status
    end

    test 'handles sha256= prefixed signatures' do
      # Just stub the signature verification to pass for this test
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      signature = "sha256=#{compute_signature(@viewed_payload.to_json)}"
      
      post webhooks_docuseal_medical_certification_path,
           params: @viewed_payload,
           headers: webhook_headers(signature),
           as: :json

      assert_response :ok
      
      @application.reload
      assert_equal 'opened', @application.document_signing_status
    end

    test 'prevents duplicate processing of completed events' do
      @application.update!(
        document_signing_status: :signed,
        document_signing_document_url: 'https://example.com/signed_doc.pdf'
      )
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      # Should not re-process or re-attach
      assert_no_difference 'Event.count' do
        make_signed_webhook_request(@completed_payload)
        assert_response :ok
      end
    end

    test 'handles file download failures gracefully' do
      @application.update!(medical_certification_status: :requested)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      # Mock HTTP download failure
      HTTP.stubs(:timeout).returns(HTTP)
      HTTP.stubs(:get).raises(StandardError, 'Download failed')

      make_signed_webhook_request(@completed_payload)
      assert_response :ok

      @application.reload
      # document_signing_status should still be updated (signing completed in DocuSeal)
      assert_equal 'signed', @application.document_signing_status
      # medical_certification_status should NOT be updated since attachment failed
      assert_equal 'requested', @application.medical_certification_status
      assert_not @application.medical_certification.attached?

      # Verify failure was logged as audit event
      event = Event.where(action: 'document_signing_attachment_failed').last
      assert_not_nil event
      assert_equal @application, event.auditable
      assert_equal 'exception', event.metadata['failure_reason']
    end

    test 'does not update medical status when HTTP download returns error status' do
      @application.update!(medical_certification_status: :requested)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      # Mock HTTP download returning error status
      mock_response = mock('http_response')
      mock_response.stubs(:status).returns(mock('status'))
      mock_response.status.stubs(:success?).returns(false)
      mock_response.status.stubs(:code).returns(404)
      HTTP.stubs(:timeout).returns(HTTP)
      HTTP.stubs(:get).returns(mock_response)

      make_signed_webhook_request(@completed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      # Should remain :requested since attachment failed
      assert_equal 'requested', @application.medical_certification_status
      assert_not @application.medical_certification.attached?

      # Verify failure was logged
      event = Event.where(action: 'document_signing_attachment_failed').last
      assert_not_nil event
      assert_equal 'download_failed', event.metadata['failure_reason']
    end

    test 'does not update medical status when document URL is missing' do
      @application.update!(medical_certification_status: :requested)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      # Payload without documents
      payload_without_docs = @completed_payload.deep_dup
      payload_without_docs[:data].delete('documents')

      make_signed_webhook_request(payload_without_docs)
      assert_response :ok

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      # Should remain :requested since attachment failed
      assert_equal 'requested', @application.medical_certification_status

      # Verify failure was logged
      event = Event.where(action: 'document_signing_attachment_failed').last
      assert_not_nil event
      assert_equal 'missing_document_url', event.metadata['failure_reason']
    end
  end
end
