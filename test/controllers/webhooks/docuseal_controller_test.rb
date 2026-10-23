# frozen_string_literal: true

require 'test_helper'

module Webhooks
  class DocusealControllerTest < ActionDispatch::IntegrationTest
    setup do
      @system_user = ensure_system_audit_actor!

      @application = create(:application, :in_progress,
                            document_signing_service: 'docuseal',
                            document_signing_submission_id: 'sub_123456',
                            document_signing_status: :sent,
                            medical_certification_status: :requested)

      @webhook_secret = 'test_webhook_secret'
      Rails.application.credentials.stubs(:webhook_secret).returns(@webhook_secret)

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

    test 'missing or blank webhook credentials reject completion without changing application or delivery records' do
      [nil, '', ' '].each do |secret|
        Rails.application.credentials.stubs(:webhook_secret).returns(secret)

        assert_rejected_completion(webhook_headers(compute_signature(@completed_payload.to_json)))
        assert_rejected_completion(webhook_headers("sha256=#{compute_signature(@completed_payload.to_json)}", 'X-DocuSeal-Signature'))
      end
    end

    test 'missing or invalid webhook signatures reject completion without changing application or delivery records' do
      [nil, '', 'wrong-signature'].each do |signature|
        assert_rejected_completion(webhook_headers(signature))
      end
      assert_rejected_completion(webhook_headers('wrong-signature', 'X-DocuSeal-Signature'))
    end

    test 'configured secret authenticates supported signature headers and prefixed signatures' do
      [['X-Webhook-Signature', ''], ['X-DocuSeal-Signature', ''], ['X-DocuSeal-Signature', 'sha256=']].each_with_index do |(header, prefix), index|
        application = create(:application, :in_progress, user: @application.user,
                                                         document_signing_service: 'docuseal', document_signing_submission_id: "signature_#{index}",
                                                         document_signing_status: :sent, medical_certification_status: :requested)
        payload = @viewed_payload.deep_dup
        payload[:data]['submission_id'] = application.document_signing_submission_id
        signature = compute_signature(payload.to_json)

        assert_difference -> { Event.where(action: 'document_signing_viewed', auditable: application).count }, 1 do
          post webhooks_docuseal_medical_certification_path, params: payload, headers: webhook_headers("#{prefix}#{signature}", header), as: :json
        end

        assert_response :ok
        assert_equal 'opened', application.reload.document_signing_status
      end
    end

    test 'accepts valid form.viewed event' do
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      make_signed_webhook_request(@viewed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'opened', @application.document_signing_status

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

      @application.reload
      assert_equal 'opened', @application.document_signing_status

      event = Event.where(action: 'document_signing_started').last
      assert_not_nil event
      assert_equal @application, event.auditable
    end

    test 'handles form.completed event with approved medical cert status' do
      @application.update!(medical_certification_status: :approved)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      mock_successful_docuseal_download

      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      complete_docuseal_scan!

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      assert_not_nil @application.document_signing_signed_at
      assert_equal 'approved', @application.medical_certification_status
      # The signed form remains available for staff review after certification approval.
      assert_not @application.medical_certification.attached?
      assert_equal 1, @application.additional_medical_certifications.count
      assert_equal 'certification_approved', @application.additional_medical_certifications.first.blob.metadata['retention_reason']
      assert_equal 'https://example.com/signed_doc.pdf', @application.document_signing_document_url
      assert_equal 'https://example.com/audit_log', @application.document_signing_audit_url

      event = Event.where(action: 'document_signing_completed').last
      assert_not_nil event
      assert_equal @application, event.auditable
    end

    test 'completion quarantines the document until its scan passes and duplicate delivery reuses the scan' do
      mock_successful_docuseal_download
      assert_difference 'DocumentScan.count', 1 do
        assert_no_difference 'ActiveStorage::Attachment.count' do
          make_signed_webhook_request(@completed_payload)
          assert_response :ok
        end
      end

      scan = DocumentScan.find_by!(continuation: 'docuseal')
      assert_predicate scan, :pending?
      assert_empty scan.blob.attachments
      assert_equal 'sent', @application.reload.document_signing_status
      assert_equal 'requested', @application.medical_certification_status
      assert_nil @application.document_signing_signed_at
      assert_nil @application.document_signing_document_url
      assert_not Event.exists?(auditable: @application, action: 'document_signing_completed')

      HTTP.expects(:get).never
      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count', 'Event.count'] do
        make_signed_webhook_request(@completed_payload)
        assert_response :ok
      end
      complete_docuseal_scan!
      assert_equal scan.blob_id, @application.reload.medical_certification.blob.id
      assert_equal 'signed', @application.document_signing_status
      assert_equal 'received', @application.medical_certification_status

      assert_no_difference ['ActiveStorage::Attachment.count', 'Event.count', 'Notification.count'] do
        DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      end
    end

    test 'pending provider scans cannot complete signing' do
      mock_successful_docuseal_download
      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      scan = DocumentScan.find_by!(continuation: 'docuseal')

      assert_no_difference ['ActiveStorage::Attachment.count', 'Event.count', 'Notification.count'] do
        assert_raises(DocumentScan::NotCleared) { DocumentSigning::AcceptScannedDocument.call(scan) }
      end
      assert_equal 'sent', @application.reload.document_signing_status
      assert_equal 'requested', @application.medical_certification_status
    end

    test 'a blocked DocuSeal verdict records one failure and alerts only admins without accepting the PDF' do
      create(:admin)
      scan = stage_docuseal_scan!
      work = scan.claim_work!
      result = AttachmentScanner::Client::Result.new(status: 'found', scan_id: SecureRandom.uuid, sha256: scan.sha256,
                                                     byte_size: scan.blob.byte_size)

      assert_enqueued_with(job: DocumentSigning::AcceptScannedDocumentJob, args: [scan.id]) do
        scan.complete_work!(token: work.token, result: result)
      end
      assert_predicate scan.reload, :blocked?
      assert_terminal_docuseal_failure(scan, 'scan_blocked')
    end

    test 'a terminal scanner failure records its safe code and alerts admins once' do
      create(:admin)
      scan = stage_docuseal_scan!
      work = scan.claim_work!

      assert_enqueued_with(job: DocumentSigning::AcceptScannedDocumentJob, args: [scan.id]) do
        scan.fail_work!(token: work.token, code: 'unauthorized', retryable: false)
      end
      assert_predicate scan.reload, :failed?
      assert_terminal_docuseal_failure(scan, 'scan_failed')
      event = Event.find_by!(auditable: @application, action: 'document_signing_attachment_failed')
      assert_equal 'unauthorized', event.metadata['failure_details']
    end

    test 'distinct failed DocuSeal snapshots keep separate audits within the dedup window' do
      freeze_time do
        create(:admin)
        first = stage_docuseal_scan!
        @completed_payload[:data]['documents'].first['url'] = 'https://example.com/second_signed_doc.pdf'
        second = nil
        assert_difference 'DocumentScan.count', 1 do
          second = stage_docuseal_scan!
        end
        assert_not_equal first.id, second.id
        scans = [first, second]
        scans.each { |scan| scan.update!(status: :blocked, completed_at: Time.current, last_error_code: 'scan_found') }

        assert_difference -> { Event.where(auditable: @application, action: 'document_signing_attachment_failed').count }, 2 do
          assert_difference 'Notification.count', 2 * User.admins.count do
            scans.each { |scan| DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id) }
          end
        end

        events = Event.where(auditable: @application, action: 'document_signing_attachment_failed')
        assert_equal scans.map(&:id).sort, events.map { |event| event.metadata['document_scan_id'] }.sort
        assert_equal 2, events.map { |event| event.metadata['operation_id'] }.uniq.size
        assert(scans.all? { |scan| scan.reload.continued_at && !DocumentScan.cleared?(scan.blob) })
        assert_no_difference ['Event.count', 'Notification.count', 'ActiveStorage::Attachment.count'] do
          scans.each { |scan| DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id) }
        end
      end
    end

    test 'an expired DocuSeal scan remains blocked and recovery records its terminal failure' do
      create(:admin)
      scan = stage_docuseal_scan!
      scan.update!(created_at: 2.hours.ago, next_attempt_at: nil)

      assert_enqueued_with(job: DocumentSigning::AcceptScannedDocumentJob, args: [scan.id]) do
        RecoverDocumentScansJob.perform_now
      end

      assert_predicate scan.reload, :failed?
      assert_terminal_docuseal_failure(scan, 'scan_failed')
      assert_equal 'scan_unresolved', Event.find_by!(auditable: @application, action: 'document_signing_attachment_failed').metadata['failure_details']
    end

    test 'a terminal scan for a superseded DocuSeal request creates no failure notice for the newer request' do
      create(:admin)
      scan = stage_docuseal_scan!
      scan.update!(status: :blocked, completed_at: Time.current, last_error_code: 'scan_found')
      @application.update!(document_signing_submission_id: 'new-submission')

      assert_no_difference ['ActiveStorage::Attachment.count', 'Event.count', 'Notification.count'] do
        DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      end

      assert scan.reload.continued_at
      assert_equal 'new-submission', @application.reload.document_signing_submission_id
      assert_equal 'sent', @application.document_signing_status
    end

    test 'a failure audit error rolls back admin notices and leaves the continuation retryable' do
      create(:admin)
      scan = stage_docuseal_scan!
      scan.update!(status: :failed, completed_at: Time.current, last_error_code: 'scan_unresolved')
      AuditEventService.expects(:log).with do |**attributes|
        attributes[:action] == 'document_signing_attachment_failed'
      end.raises(ActiveRecord::RecordInvalid.new(Event.new))

      assert_no_difference ['Event.count', 'Notification.count', 'ActiveStorage::Attachment.count'] do
        assert_raises(ActiveRecord::RecordInvalid) { DocumentSigning::AcceptScannedDocument.call(scan) }
      end
      assert_nil scan.reload.continued_at
      assert_equal 'sent', @application.reload.document_signing_status
    end

    test 'an admin notice failure rolls back the failure audit and leaves the continuation retryable' do
      create(:admin)
      scan = stage_docuseal_scan!
      scan.update!(status: :blocked, completed_at: Time.current, last_error_code: 'scan_found')
      NotificationService.expects(:create_and_deliver!).returns(nil)

      assert_no_difference ['Event.count', 'Notification.count', 'ActiveStorage::Attachment.count'] do
        assert_raises(ActiveRecord::RecordNotSaved) { DocumentSigning::AcceptScannedDocument.call(scan) }
      end
      assert_nil scan.reload.continued_at
      assert_equal 'sent', @application.reload.document_signing_status
    end

    test 'a duplicate completion does not acknowledge a snapshot that was never made ready' do
      mock_successful_docuseal_download
      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      scan = DocumentScan.find_by!(continuation: 'docuseal')
      scan.update!(next_attempt_at: nil)
      HTTP.expects(:get).never

      assert_no_enqueued_jobs(only: DocumentScanJob) do
        assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count', 'Event.count', 'Notification.count'] do
          make_signed_webhook_request(@completed_payload)
          assert_response :service_unavailable
        end
      end
      assert_nil scan.reload.next_attempt_at
      assert_equal 'sent', @application.reload.document_signing_status
      assert_nil @application.document_signing_signed_at
    end

    test 'a pending result cannot complete a newer signing request or changed provider' do
      mock_successful_docuseal_download
      make_signed_webhook_request(@completed_payload)
      scan = DocumentScan.find_by!(continuation: 'docuseal')
      scan.update!(status: :clean)

      [{ document_signing_submission_id: 'new-submission' }, { medical_provider_email: 'new-provider@example.com' }].each do |changes|
        @application.update!(changes)
        assert_no_difference ['ActiveStorage::Attachment.count', 'Event.count', 'Notification.count'] do
          assert_equal :superseded, DocumentSigning::AcceptScannedDocument.call(scan)
        end
        assert_equal 'sent', @application.reload.document_signing_status
        assert_nil @application.document_signing_signed_at
        @application.update!(document_signing_submission_id: 'sub_123456')
      end
    end

    test 'scan delays retain the original request time for certification placement' do
      requested_at = 2.days.ago.change(usec: 0)
      @application.update!(document_signing_requested_at: requested_at)
      mock_successful_docuseal_download
      make_signed_webhook_request(@completed_payload)
      record_certification_rejection(at: 1.day.ago)

      scan = complete_docuseal_scan!
      assert_equal requested_at, Time.iso8601(scan.context.fetch('requested_at'))
      assert_equal 'rejected', @application.reload.medical_certification_status
      assert_not @application.medical_certification.attached?
      assert_equal [scan.blob_id], @application.additional_medical_certifications.blobs.ids
      assert_equal 'request_predates_rejection', scan.blob.reload.metadata['retention_reason']
    end

    test 'non-HTTPS document URLs do not reach the HTTP client or scanner' do
      payload = @completed_payload.deep_dup
      payload[:data]['documents'].first['url'] = 'http://internal.invalid/private.pdf'
      HTTP.expects(:get).never
      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'] do
        make_signed_webhook_request(payload)
        assert_response :service_unavailable
      end
      assert_equal 'sent', @application.reload.document_signing_status
    end

    test 'oversized provider downloads stop before scan allocation' do
      bytes = '%PDF-1.4'.ljust(ProofUploadFormats.max_bytes(:certification) + 1, 'x')
      mock_successful_docuseal_download(bytes: bytes)
      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'] do
        make_signed_webhook_request(@completed_payload)
        assert_response :service_unavailable
      end
      assert_equal 'sent', @application.reload.document_signing_status
    end

    test 'a completion audit failure rolls back attachment signing status and notifications' do
      mock_successful_docuseal_download
      make_signed_webhook_request(@completed_payload)
      scan = DocumentScan.find_by!(continuation: 'docuseal')
      scan.update!(status: :clean)
      original = AuditEventService.method(:log)
      failing_audit = lambda do |**attributes|
        raise ActiveRecord::RecordInvalid, Event.new if attributes[:action] == 'document_signing_completed'

        original.call(**attributes)
      end

      assert_no_difference ['ActiveStorage::Attachment.count', 'Event.count', 'Notification.count', 'ApplicationStatusChange.count'] do
        AuditEventService.stub(:log, failing_audit) do
          assert_raises(ActiveRecord::RecordInvalid) { DocumentSigning::AcceptScannedDocument.call(scan) }
        end
      end
      assert_equal 'sent', @application.reload.document_signing_status
      assert_equal 'requested', @application.medical_certification_status
      assert_nil @application.document_signing_document_url
      assert_equal :completed, DocumentSigning::AcceptScannedDocument.call(scan)
      assert_equal scan.blob_id, @application.reload.medical_certification.blob.id
    end

    test 'repeated approved completion adds no events after the document URL is stored' do
      @application.update!(medical_certification_status: :approved)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      mock_successful_docuseal_download

      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      complete_docuseal_scan!

      @application.reload
      assert_equal 'https://example.com/signed_doc.pdf', @application.document_signing_document_url

      assert_no_difference 'Event.count' do
        make_signed_webhook_request(@completed_payload)
        assert_response :ok
      end
    end

    test 'handles form.completed event with rejected medical cert status' do
      record_certification_rejection(at: 2.days.ago)
      @application.update!(document_signing_requested_at: 1.day.ago)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      mock_successful_docuseal_download

      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      complete_docuseal_scan!

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      assert_not_nil @application.document_signing_signed_at
      assert_equal 'received', @application.medical_certification_status
      assert @application.medical_certification.attached?
      assert_equal 'https://example.com/audit_log', @application.document_signing_audit_url
    end

    test 'handles form.completed event with requested medical cert status' do
      @application.update!(medical_certification_status: :requested)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      mock_successful_docuseal_download

      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      complete_docuseal_scan!

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      assert_equal 'received', @application.medical_certification_status
      assert @application.medical_certification.attached?
    end

    test 'late DocuSeal completion does not overwrite certification received through secure upload' do
      @application.update!(medical_certification_status: :received)
      @application.medical_certification.attach(
        io: StringIO.new('secure upload content'),
        filename: 'secure_upload.pdf',
        content_type: 'application/pdf'
      )
      Event.create!(
        user: @system_user,
        auditable: @application,
        action: 'cert_submitted_via_secure_form'
      )
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      mock_successful_docuseal_download

      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      complete_docuseal_scan!

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      assert_equal 'received', @application.medical_certification_status
      assert_equal 'secure_upload.pdf', @application.medical_certification.blob.filename.to_s
      assert_equal 1, @application.additional_medical_certifications.count
      assert_equal 'certification_received', @application.additional_medical_certifications.first.blob.metadata['retention_reason']

      event = Event.where(action: 'document_signing_completed', auditable: @application).last
      assert_equal 'additional_medical_certification', event.metadata['retained_as']
      assert_equal 'certification_received', event.metadata['retention_reason']
      assert event.metadata['additional_medical_certification_blob_id'].present?
    end

    test 'late DocuSeal completion after rejected secure upload is retained for deliberate review' do
      @application.update!(medical_certification_status: :rejected)
      @application.medical_certification.attach(
        io: StringIO.new('secure upload content'),
        filename: 'secure_upload.pdf',
        content_type: 'application/pdf'
      )
      Event.create!(
        user: @system_user,
        auditable: @application,
        action: 'cert_submitted_via_secure_form'
      )
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      mock_successful_docuseal_download

      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      complete_docuseal_scan!

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      assert_equal 'rejected', @application.medical_certification_status
      assert_equal 'secure_upload.pdf', @application.medical_certification.blob.filename.to_s
      assert_equal 1, @application.additional_medical_certifications.count
      assert_equal 'request_predates_rejection', @application.additional_medical_certifications.first.blob.metadata['retention_reason']

      event = Event.where(action: 'document_signing_completed', auditable: @application).last
      assert_equal 'additional_medical_certification', event.metadata['retained_as']
      assert_equal 'request_predates_rejection', event.metadata['retention_reason']
      assert event.metadata['additional_medical_certification_blob_id'].present?
    end

    test 'DocuSeal completion for a request sent before the latest rejection is kept aside' do
      @application.update!(document_signing_requested_at: 3.days.ago)
      record_certification_rejection(at: 1.day.ago)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      mock_successful_docuseal_download

      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      complete_docuseal_scan!

      @application.reload
      assert_equal 'rejected', @application.medical_certification_status
      assert_not @application.medical_certification.attached?
      assert_equal 'request_predates_rejection', @application.additional_medical_certifications.first.blob.metadata['retention_reason']
    end

    test 'late DocuSeal completion retains approved secure-uploaded certification for comparison' do
      @application.update!(medical_certification_status: :approved)
      @application.medical_certification.attach(
        io: StringIO.new('secure upload content'),
        filename: 'secure_upload.pdf',
        content_type: 'application/pdf'
      )
      Event.create!(
        user: @system_user,
        auditable: @application,
        action: 'cert_submitted_via_secure_form'
      )
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      mock_successful_docuseal_download

      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      complete_docuseal_scan!

      @application.reload
      assert_equal 'signed', @application.document_signing_status
      assert_equal 'approved', @application.medical_certification_status
      assert_equal 'secure_upload.pdf', @application.medical_certification.blob.filename.to_s
      assert_equal 1, @application.additional_medical_certifications.count

      event = Event.where(action: 'document_signing_completed', auditable: @application).last
      assert_equal 'additional_medical_certification', event.metadata['retained_as']
    end

    test 'handles form.declined event' do
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      make_signed_webhook_request(@declined_payload)
      assert_response :ok

      @application.reload
      assert_equal 'declined', @application.document_signing_status

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

    test 'acknowledges viewed events for an unknown submission ID' do
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

    test 'processes a viewed event with an alternate signature header when verification is stubbed' do
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      make_signed_webhook_request_with_alt_header(@viewed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'opened', @application.document_signing_status
    end

    test 'processes a viewed event with a prefixed signature when verification is stubbed' do
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

    test 'adds no events for an already signed completion with a document URL' do
      @application.update!(
        document_signing_status: :signed,
        document_signing_document_url: 'https://example.com/signed_doc.pdf'
      )
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      assert_no_difference 'Event.count' do
        make_signed_webhook_request(@completed_payload)
        assert_response :ok
      end
    end

    test 'a download exception leaves signing and certification incomplete' do
      @application.update!(medical_certification_status: :requested)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/Document signing intake failed for App/)).once

      HTTP.stubs(:timeout).returns(HTTP)
      HTTP.stubs(:get).raises(StandardError, 'Download failed')

      make_signed_webhook_request(@completed_payload)
      assert_response :service_unavailable

      @application.reload
      assert_equal 'sent', @application.document_signing_status
      assert_nil @application.document_signing_signed_at
      assert_equal 'requested', @application.medical_certification_status
      assert_not @application.medical_certification.attached?

      event = Event.where(action: 'document_signing_attachment_failed').last
      assert_not_nil event
      assert_equal @application, event.auditable
      assert_equal 'intake_failed', event.metadata['failure_reason']
    end

    test 'does not update medical status when HTTP download returns error status' do
      @application.update!(medical_certification_status: :requested)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      mock_response = mock('http_response')
      mock_response.stubs(:status).returns(mock('status'))
      mock_response.status.stubs(:success?).returns(false)
      mock_response.status.stubs(:code).returns(404)
      mock_response.stubs(:body).returns(HTTP::Response::Body.new(DocumentScanFixtures::ResponseStream.new('')))
      HTTP.stubs(:timeout).returns(HTTP)
      HTTP.stubs(:get).returns(mock_response)

      make_signed_webhook_request(@completed_payload)
      assert_response :service_unavailable

      @application.reload
      assert_equal 'sent', @application.document_signing_status
      assert_equal 'requested', @application.medical_certification_status
      assert_not @application.medical_certification.attached?

      event = Event.where(action: 'document_signing_attachment_failed').last
      assert_not_nil event
      assert_equal 'download_failed', event.metadata['failure_reason']
    end

    test 'does not update medical status when document URL is missing' do
      @application.update!(medical_certification_status: :requested)
      Webhooks::BaseController.any_instance.stubs(:verify_webhook_signature).returns(true)

      payload_without_docs = @completed_payload.deep_dup
      payload_without_docs[:data].delete('documents')

      make_signed_webhook_request(payload_without_docs)
      assert_response :service_unavailable

      @application.reload
      assert_equal 'sent', @application.document_signing_status
      assert_equal 'requested', @application.medical_certification_status

      event = Event.where(action: 'document_signing_attachment_failed').last
      assert_not_nil event
      assert_equal 'missing_document_url', event.metadata['failure_reason']
    end

    private

    def stage_docuseal_scan!
      mock_successful_docuseal_download
      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      DocumentScan.where(continuation: 'docuseal').order(:id).last!
    end

    def assert_terminal_docuseal_failure(scan, reason)
      admins = User.admins.order(:id).pluck(:id)
      assert_no_difference 'ActiveStorage::Attachment.count' do
        assert_difference -> { Event.where(auditable: @application, action: 'document_signing_attachment_failed').count }, 1 do
          assert_difference 'Notification.count', admins.size do
            DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
          end
        end
      end

      event = Event.find_by!(auditable: @application, action: 'document_signing_attachment_failed')
      assert_equal @system_user.id, event.user_id
      assert_equal reason, event.metadata['failure_reason']
      assert_equal scan.id, event.metadata['document_scan_id']
      assert_equal 'sub_123456', event.metadata['document_signing_submission_id']
      assert_not_includes event.metadata.to_json, 'https://'
      notices = Notification.where(notifiable: @application, action: 'attachment_failure_warning')
      assert_equal admins, notices.order(:recipient_id).pluck(:recipient_id)
      assert(notices.all? { |notice| notice.actor_id == @system_user.id && notice.metadata['document_scan_id'] == scan.id })
      assert_not_includes notices.map(&:metadata).to_json, 'https://'
      notices.each { |notice| assert_includes notice.message(notice.recipient), admin_application_path(@application) }
      assert scan.reload.continued_at
      assert_not DocumentScan.cleared?(scan.blob)
      assert_equal 'sent', @application.reload.document_signing_status
      assert_equal 'requested', @application.medical_certification_status
      assert_nil @application.document_signing_signed_at
      assert_nil @application.document_signing_document_url
      assert_not @application.medical_certification.attached?

      travel 6.seconds do
        assert_no_difference ['Event.count', 'Notification.count', 'ActiveStorage::Attachment.count'] do
          DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
        end
      end
    end

    def assert_rejected_completion(headers)
      assert_no_difference ['Event.count', 'Notification.count', 'ActiveStorage::Attachment.count', 'ActiveStorage::Blob.count'] do
        post webhooks_docuseal_medical_certification_path, params: @completed_payload, headers: headers, as: :json
      end

      assert_response :unauthorized
      @application.reload
      assert_equal 'sent', @application.document_signing_status
      assert_equal 'requested', @application.medical_certification_status
      assert_nil @application.document_signing_signed_at
      assert_nil @application.document_signing_document_url
      assert_not @application.medical_certification.attached?
    end

    def record_certification_rejection(at:)
      @application.update!(medical_certification_status: :rejected)
      ApplicationStatusChange.create!(application: @application, user: @system_user, from_status: 'requested',
                                      to_status: 'rejected', change_type: 'medical_certification', changed_at: at)
    end

    def mock_successful_docuseal_download(bytes: nil)
      mock_response = mock('http_response')
      mock_response.stubs(:status).returns(mock('status'))
      mock_response.status.stubs(:success?).returns(true)
      bytes ||= file_fixture('medical_certification_valid.pdf').binread
      mock_response.stubs(:body).returns(HTTP::Response::Body.new(DocumentScanFixtures::ResponseStream.new(bytes)))
      HTTP.stubs(:timeout).returns(HTTP)
      HTTP.stubs(:get).returns(mock_response)
      mock_response
    end

    def complete_docuseal_scan!
      scan = DocumentScan.find_by!(continuation: 'docuseal')
      scan.update!(status: :clean)
      DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      scan
    end
  end
end
