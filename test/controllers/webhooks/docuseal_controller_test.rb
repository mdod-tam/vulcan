# frozen_string_literal: true

require 'test_helper'

module Webhooks
  class DocusealControllerTest < ActionDispatch::IntegrationTest
    setup do
      @system_user = ensure_system_audit_actor!

      @application = create(:application, :in_progress,
                            document_signing_service: 'docuseal',
                            document_signing_submission_id: 'sub_123456',
                            document_signing_submitter_id: 'signer_42',
                            document_signing_requested_at: 1.day.ago,
                            document_signing_status: :sent,
                            medical_certification_status: :requested)

      @webhook_secret = 'whsec_fixture_docuseal_signing_secret'
      Rails.application.credentials.stubs(:webhook_secret).returns(@webhook_secret)

      ApplicationController.any_instance.stubs(:authenticate_user!).returns(true)
      ApplicationController.any_instance.stubs(:require_login).returns(true)

      @viewed_payload = {
        event_type: 'form.viewed',
        timestamp: 1.hour.ago.utc.iso8601(6),
        data: {
          'id' => 'signer_42',
          'submission_id' => 'sub_123456',
          'email' => 'doctor@example.com'
        }
      }

      @started_payload = {
        event_type: 'form.started',
        timestamp: 1.hour.ago.utc.iso8601(6),
        data: {
          'id' => 'signer_42',
          'submission_id' => 'sub_123456',
          'email' => 'doctor@example.com'
        }
      }

      @completed_payload = {
        event_type: 'form.completed',
        data: {
          'id' => 'signer_42',
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
        timestamp: 1.hour.ago.utc.iso8601(6),
        data: {
          'id' => 'signer_42',
          'submission_id' => 'sub_123456',
          'email' => 'doctor@example.com'
        }
      }
    end

    def make_signed_webhook_request(payload)
      body = payload.to_json
      post webhooks_docuseal_medical_certification_path, params: body, headers: webhook_headers(compute_signature(body))
    end

    def webhook_headers(signature = nil, header = 'X-Docuseal-Signature')
      headers = { 'Content-Type' => 'application/json' }
      headers[header] = signature if signature
      headers
    end

    def compute_signature(payload, timestamp: Time.current.to_i, secret: @webhook_secret)
      digest = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{payload}")
      "#{timestamp}.#{digest}"
    end

    test 'official DocuSeal HMAC vector authenticates exact UTF8 request bytes' do
      travel_to Time.utc(2026, 10, 23, 12) do
        body = "{ \"event_type\": \"form.viewed\", \"timestamp\": \"2026-10-23T11:59:00Z\", \"data\": { \"id\": \"signer_42\", \"submission_id\": \"sub_123456\", \"name\": \"Doctora García\" } }\n"
        # Fixed vector generated independently with Python's hmac library.
        signature = '1792756800.4166bae5e9fe205c0a72895f22c565f11f54d051e323bd01a8c19e683c363b99'

        assert_difference -> { Event.where(action: 'document_signing_viewed', auditable: @application).count }, 1 do
          post webhooks_docuseal_medical_certification_path, params: body,
                                                             headers: { 'Content-Type' => 'application/json', 'X-Docuseal-Signature' => signature }
        end
        assert_response :ok
        assert_equal 'opened', @application.reload.document_signing_status
      end
    end

    test 'missing or blank webhook credentials reject completion without changing application or delivery records' do
      HTTP.expects(:timeout).never
      [nil, '', ' '].each do |secret|
        Rails.application.credentials.stubs(:webhook_secret).returns(secret)
        assert_rejected_completion(webhook_headers(compute_signature(@completed_payload.to_json)))
      end
    end

    test 'missing malformed and legacy webhook signatures reject completion without side effects' do
      HTTP.expects(:timeout).never
      body = @completed_payload.to_json
      timestamp = Time.current.to_i
      digest = compute_signature(body).split('.', 2).last
      bare = OpenSSL::HMAC.hexdigest('SHA256', @webhook_secret, body)
      malformed = [nil, '', 'wrong-signature', bare, "sha256=#{bare}", "#{timestamp}.", ".#{digest}",
                   "not-a-timestamp.#{digest}", "#{timestamp}.#{'g' * 64}", "#{timestamp}.#{'a' * 63}",
                   "#{timestamp}.#{digest}.extra", "#{timestamp}.0.#{digest}"]
      malformed.each { |signature| assert_rejected_completion(webhook_headers(signature)) }
      assert_rejected_completion(webhook_headers(compute_signature(body), 'X-Webhook-Signature'))
    end

    test 'official DocuSeal signatures accept the inclusive five minute clock boundaries' do
      freeze_time do
        [-300, 0, 300].each_with_index do |offset, index|
          application = create(:application, :in_progress, user: @application.user,
                                                           document_signing_service: 'docuseal', document_signing_submission_id: "signature_#{index}",
                                                           document_signing_submitter_id: 'signer_42', document_signing_requested_at: 1.day.ago,
                                                           document_signing_status: :sent, medical_certification_status: :requested)
          payload = @viewed_payload.deep_dup
          payload[:data]['submission_id'] = application.document_signing_submission_id
          body = payload.to_json
          signature = compute_signature(body, timestamp: Time.current.to_i + offset)

          assert_difference -> { Event.where(action: 'document_signing_viewed', auditable: application).count }, 1 do
            post webhooks_docuseal_medical_certification_path, params: body, headers: webhook_headers(signature)
          end
          assert_response :ok
          assert_equal 'opened', application.reload.document_signing_status
        end
      end
    end

    test 'stale and future DocuSeal signatures outside the tolerance reject completion' do
      HTTP.expects(:timeout).never
      freeze_time do
        [-301, 301].each do |offset|
          signature = compute_signature(@completed_payload.to_json, timestamp: Time.current.to_i + offset)
          assert_rejected_completion(webhook_headers(signature))
        end
      end
    end

    test 'DocuSeal signatures reject a wrong secret or tampered timestamp and raw body' do
      HTTP.expects(:timeout).never
      body = @completed_payload.to_json
      assert_rejected_completion(webhook_headers(compute_signature(body, secret: 'whsec_wrong_signing_secret')))
      signature = compute_signature(body)
      assert_rejected_completion(webhook_headers(signature), body: "#{body} ")
      assert_rejected_completion(webhook_headers(signature), body: body.sub('doctor@example.com', 'other@example.com'))
      assert_rejected_completion(webhook_headers("#{Time.current.to_i + 1}.#{signature.split('.', 2).last}"))
    end

    test 'a freshly signed retry reuses the scan after its original signature expires' do
      mock_successful_docuseal_download
      original_signature = compute_signature(@completed_payload.to_json)
      make_signed_webhook_request(@completed_payload)
      assert_response :ok
      scan = DocumentScan.find_by!(continuation: 'docuseal')

      travel 6.minutes do
        assert_rejected_completion(webhook_headers(original_signature))
        HTTP.expects(:get).never
        assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count', 'Event.count'] do
          make_signed_webhook_request(@completed_payload)
          assert_response :ok
        end
        complete_docuseal_scan!
      end
      assert_equal scan.blob_id, @application.reload.medical_certification.blob_id
      assert_empty @application.additional_medical_certifications
      assert_equal 1, Event.where(auditable: @application, action: 'document_signing_completed').count
    end

    test 'accepts valid form.viewed event' do
      make_signed_webhook_request(@viewed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'opened', @application.document_signing_status

      event = Event.where(action: 'document_signing_viewed').last
      assert_not_nil event
      assert_equal @application, event.auditable
      assert_equal 'sub_123456', event.metadata['document_signing_submission_id']
      assert_equal @system_user.id, event.user_id
      assert_equal @viewed_payload[:timestamp], event.metadata['viewed_at']
    end

    test 'accepts valid form.started event' do
      @application.update!(document_signing_status: :opened)

      make_signed_webhook_request(@started_payload)
      assert_response :ok

      @application.reload
      assert_equal 'opened', @application.document_signing_status

      event = Event.where(action: 'document_signing_started').last
      assert_not_nil event
      assert_equal @application, event.auditable
    end

    %w[viewed started declined].each do |activity|
      test "an exact signed #{activity} replay after the audit window creates no second event" do
        payload = instance_variable_get("@#{activity}_payload")
        body = payload.to_json
        signature = compute_signature(body)
        action = "document_signing_#{activity}"

        assert_difference -> { Event.where(auditable: @application, action: action).count }, 1 do
          post webhooks_docuseal_medical_certification_path, params: body, headers: webhook_headers(signature)
          assert_response :ok
        end
        first_event = Event.find_by!(auditable: @application, action: action)
        first_update = @application.reload.updated_at

        travel 6.seconds do
          assert_no_difference ['Event.count', 'Notification.count', 'ApplicationStatusChange.count'] do
            post webhooks_docuseal_medical_certification_path, params: body, headers: webhook_headers(signature)
            assert_response :ok
          end
        end
        assert_equal first_update, @application.reload.updated_at
        assert_equal @system_user.id, first_event.user_id
        assert_equal payload[:timestamp], first_event.metadata["#{activity}_at"]
      end

      test "a freshly signed #{activity} retry keeps its identity when provider data and URLs change" do
        payload = instance_variable_get("@#{activity}_payload")
        make_signed_webhook_request(payload)
        assert_response :ok

        retry_payload = payload.deep_dup
        retry_payload[:data].merge!('status' => 'completed', 'updated_at' => Time.current.iso8601,
                                    'documents' => [{ 'url' => 'https://example.com/document.pdf?token=rotated' }],
                                    'audit_log_url' => 'https://example.com/audit.pdf?token=rotated')
        travel 6.minutes do
          assert_no_difference ['Event.count', 'Notification.count'] do
            make_signed_webhook_request(retry_payload)
            assert_response :ok
          end
        end
      end

      test "separate #{activity} events within the audit window retain separate history" do
        payload = instance_variable_get("@#{activity}_payload")
        later_payload = payload.deep_dup
        later_payload[:timestamp] = (Time.iso8601(payload[:timestamp]) + 1.second).iso8601(6)

        freeze_time do
          assert_difference -> { Event.where(auditable: @application, action: "document_signing_#{activity}").count }, 2 do
            [payload, later_payload].each do |event_payload|
              make_signed_webhook_request(event_payload)
              assert_response :ok
            end
          end
        end
        events = Event.where(auditable: @application, action: "document_signing_#{activity}").order(:id)
        assert_equal([payload[:timestamp], later_payload[:timestamp]], events.map { |event| event.metadata["#{activity}_at"] })
        assert_equal 2, events.map { |event| event.metadata['operation_id'] }.uniq.size
      end

      test "a new signing request can record #{activity} with the same provider event timestamp" do
        payload = instance_variable_get("@#{activity}_payload")
        assert_difference -> { Event.where(auditable: @application, action: "document_signing_#{activity}").count }, 2 do
          make_signed_webhook_request(payload)
          assert_response :ok
          @application.update!(document_signing_requested_at: @application.document_signing_requested_at + 1.second)
          make_signed_webhook_request(payload)
          assert_response :ok
        end
      end

      test "#{activity} ignores a different submitter and a superseded submission" do
        payload = instance_variable_get("@#{activity}_payload").deep_dup
        payload[:data]['id'] = 'other_signer'
        assert_no_difference 'Event.count' do
          make_signed_webhook_request(payload)
          assert_response :ok
        end
        assert_equal 'sent', @application.reload.document_signing_status

        stale_application = Application.find(@application.id)
        @application.update!(document_signing_submission_id: 'new_submission')
        DocusealController.any_instance.stubs(:find_application).returns(stale_application)
        assert_no_difference 'Event.count' do
          make_signed_webhook_request(instance_variable_get("@#{activity}_payload"))
          assert_response :ok
        end
        assert_equal 'sent', @application.reload.document_signing_status
      end

      test "#{activity} rejects missing or malformed event identity without side effects" do
        payload = instance_variable_get("@#{activity}_payload")
        invalid_payloads = [nil, '', 'not-a-timestamp', 123, []].map { |timestamp| payload.merge(timestamp: timestamp) }
        invalid_payloads << payload.except(:timestamp)
        %w[id submission_id].each do |field|
          invalid_payloads.concat([nil, '', [], {}].map do |identifier|
            payload.deep_dup.tap { |invalid| invalid[:data][field] = identifier }
          end)
          invalid_payloads << payload.deep_dup.tap { |invalid| invalid[:data].delete(field) }
        end

        invalid_payloads.each do |invalid|
          assert_no_difference ['Event.count', 'Notification.count', 'ApplicationStatusChange.count'] do
            make_signed_webhook_request(invalid)
            assert_response :unprocessable_content
          end
          assert_equal 'sent', @application.reload.document_signing_status
        end
      end

      test "delayed #{activity} preserves signed and declined request states" do
        signed_at = 10.minutes.ago.change(usec: 0)
        %i[signed declined].each do |state|
          @application.update!(document_signing_status: state, document_signing_signed_at: signed_at,
                               document_signing_document_url: 'https://example.com/signed.pdf', medical_certification_status: :received)
          payload = instance_variable_get("@#{activity}_payload").deep_dup
          payload[:timestamp] = (Time.iso8601(payload[:timestamp]) + (state == :signed ? 1 : 2).seconds).iso8601(6)

          assert_difference -> { Event.where(auditable: @application, action: "document_signing_#{activity}").count }, 1 do
            make_signed_webhook_request(payload)
            assert_response :ok
          end
          @application.reload
          assert_equal state.to_s, @application.document_signing_status
          assert_equal signed_at, @application.document_signing_signed_at
          assert_equal 'https://example.com/signed.pdf', @application.document_signing_document_url
          assert_equal 'received', @application.medical_certification_status
        end
      end
    end

    %w[viewed declined].each do |activity|
      test "a #{activity} audit failure rolls back the signing status" do
        AuditEventService.expects(:log).with(action: "document_signing_#{activity}", actor: @system_user,
                                             auditable: anything, metadata: anything).raises(ActiveRecord::RecordInvalid)

        assert_no_difference 'Event.count' do
          make_signed_webhook_request(instance_variable_get("@#{activity}_payload"))
          assert_response :unprocessable_content
        end
        assert_equal 'sent', @application.reload.document_signing_status
      end
    end

    test 'handles form.completed event with approved medical cert status' do
      @application.update!(medical_certification_status: :approved)
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

    test 'rotated provider URLs reuse one pending request and produce one completion' do
      scan = stage_docuseal_scan!
      @completed_payload[:data]['documents'].first['url'] = 'https://example.com/signed_doc.pdf?token=rotated'
      HTTP.expects(:get).never

      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count', 'Event.count'] do
        make_signed_webhook_request(@completed_payload)
        assert_response :ok
      end
      complete_docuseal_scan!
      assert_equal scan.blob_id, @application.reload.medical_certification.blob_id
      assert_empty @application.additional_medical_certifications
      assert_equal 1, Event.where(auditable: @application, action: 'document_signing_completed').count
    end

    test 'a refused provider document is acknowledged once without staging or retry audit noise' do
      mock_successful_docuseal_download(bytes: '<html>not a PDF</html>')
      assert_difference -> { Event.where(auditable: @application, action: 'document_signing_attachment_failed').count }, 1 do
        assert_no_difference ['DocumentScan.count', 'ActiveStorage::Attachment.count'] do
          make_signed_webhook_request(@completed_payload)
          assert_response :ok
          travel 6.seconds do
            make_signed_webhook_request(@completed_payload)
            assert_response :ok
          end
        end
      end
      assert_equal 'sent', @application.reload.document_signing_status
    end

    test 'permanent certification acceptance failures stop recovery and record giving up once' do
      scan = stage_docuseal_scan!
      scan.update!(status: :clean)
      MedicalCertificationAttachmentService.expects(:accept_submission).once.returns(success: false, error: ArgumentError.new('rejected'))

      assert_difference -> { Event.where(action: 'document_signing_attachment_failed').count }, 1 do
        assert_no_difference 'ActiveStorage::Attachment.count' do
          DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
        end
      end
      assert scan.reload.continued_at
      event = Event.where(action: 'document_signing_attachment_failed').order(:id).last!
      assert_equal 'continuation_gave_up', event.metadata['failure_reason']
      assert_equal scan.id, event.metadata['document_scan_id']
      assert_not scan.blob.reload.metadata.key?('source')
      assert_equal 'sent', @application.reload.document_signing_status
      assert_no_enqueued_jobs(only: DocumentSigning::AcceptScannedDocumentJob) { RecoverDocumentScansJob.perform_now }
      assert_no_difference ['Event.count', 'Notification.count', 'ActiveStorage::Attachment.count'] do
        DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      end
    end

    test 'missing continuation applications or actors are terminal and leave a durable failure record' do
      %w[application_id actor_id].each do |key|
        @application.update!(document_signing_requested_at: Time.current)
        scan = stage_docuseal_scan!
        scan.update!(status: :clean, context: scan.context.merge(key => -1))

        assert_difference -> { Event.where(action: 'document_signing_attachment_failed').count }, 1 do
          DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
        end
        assert scan.reload.continued_at
        event = Event.where(action: 'document_signing_attachment_failed').order(:id).last!
        assert_equal 'continuation_gave_up', event.metadata['failure_reason']
        assert_equal scan.id, event.metadata['document_scan_id']
        assert_no_enqueued_jobs(only: DocumentSigning::AcceptScannedDocumentJob) { RecoverDocumentScansJob.perform_now }
      end
    end

    test 'a callback for another submitter cannot stage a certification for the stored request' do
      @completed_payload[:data]['id'] = 'another-signer'
      HTTP.expects(:get).never
      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Attachment.count', 'Event.count'] do
        make_signed_webhook_request(@completed_payload)
        assert_response :ok
      end
      assert_equal 'sent', @application.reload.document_signing_status
    end

    test 'transient continuation errors back off and stop after three attempts' do
      scan = stage_docuseal_scan!
      scan.update!(status: :clean)
      MedicalCertificationAttachmentService.expects(:accept_submission).times(3).raises(ActiveRecord::Deadlocked)

      DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      assert_nil scan.reload.continued_at
      assert_equal 1, scan.continuation_attempts
      assert_operator scan.continuation_next_attempt_at, :>, Time.current
      assert_no_enqueued_jobs(only: DocumentSigning::AcceptScannedDocumentJob) { RecoverDocumentScansJob.perform_now }
      assert_no_difference('Event.count') { DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id) }
      assert_equal 1, scan.reload.continuation_attempts

      travel_to(scan.continuation_next_attempt_at + 1.second) do
        DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      end
      assert_equal 2, scan.reload.continuation_attempts
      assert_nil scan.continued_at
      travel_to(scan.continuation_next_attempt_at + 1.second) do
        DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      end
      assert scan.reload.continued_at
      assert_equal 3, scan.continuation_attempts
      assert_equal 'ActiveRecord::Deadlocked', scan.continuation_error_code
      assert_equal 'continuation_gave_up', Event.where(action: 'document_signing_attachment_failed').order(:id).last!.metadata['failure_reason']
      assert_no_enqueued_jobs(only: DocumentSigning::AcceptScannedDocumentJob) { RecoverDocumentScansJob.perform_now }
    end

    test 'an interrupted final continuation attempt becomes terminal when its lease expires' do
      scan = stage_docuseal_scan!
      scan.update!(status: :clean, continuation_attempts: 3, continuation_next_attempt_at: 1.second.ago)
      DocumentSigning::AcceptScannedDocument.expects(:call).never

      assert_difference -> { Event.where(action: 'document_signing_attachment_failed').count }, 1 do
        DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      end
      assert scan.reload.continued_at
      assert_equal 'continuation_worker_interrupted', scan.continuation_error_code
      assert_no_enqueued_jobs(only: DocumentSigning::AcceptScannedDocumentJob) { RecoverDocumentScansJob.perform_now }
      assert_no_difference ['Event.count', 'ActiveStorage::Attachment.count'] do
        DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      end
    end

    test 'a job error after committed continuation does not retry or write a false failure' do
      scan = stage_docuseal_scan!
      scan.update!(status: :clean)
      original = DocumentSigning::AcceptScannedDocument.method(:call)
      DocumentSigning::AcceptScannedDocument.stub(:call, lambda { |document_scan|
        original.call(document_scan)
        raise ActiveRecord::Deadlocked
      }) do
        DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
      end
      assert scan.reload.continued_at
      assert @application.reload.medical_certification.attached?
      assert_equal 1, Event.where(action: 'document_signing_completed', auditable: @application).count
      assert_not Event.exists?(action: 'document_signing_attachment_failed', auditable: @application)
      assert_nil scan.continuation_error_code
      assert_no_enqueued_jobs(only: DocumentSigning::AcceptScannedDocumentJob) { RecoverDocumentScansJob.perform_now }
    end

    test 'an unverifiable continuation error propagates without a false terminal result' do
      scan = stage_docuseal_scan!
      scan.update!(status: :clean)
      DocumentScan.stubs(:find_by).with(id: scan.id).returns(scan)
      DocumentSigning::AcceptScannedDocument.expects(:call).raises(ActiveRecord::Deadlocked)
      reloads = 0
      scan.define_singleton_method(:reload) do |*args, **options|
        reloads += 1
        raise ActiveRecord::ConnectionNotEstablished, 'unavailable' if reloads > 1

        super(*args, **options)
      end

      assert_no_enqueued_jobs(only: DocumentSigning::AcceptScannedDocumentJob) do
        assert_raises(ActiveRecord::ConnectionNotEstablished) { DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id) }
      end
      assert_not Event.exists?(action: 'document_signing_attachment_failed', auditable: @application)
      assert_nil DocumentScan.find(scan.id).continued_at
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

    test 'distinct signing requests keep separate failure audits within the dedup window' do
      freeze_time do
        create(:admin)
        scans = []

        assert_difference -> { Event.where(auditable: @application, action: 'document_signing_attachment_failed').count }, 2 do
          assert_difference 'Notification.count', 2 * User.admins.count do
            2.times do |index|
              if index.positive?
                @application.update!(document_signing_requested_at: @application.document_signing_requested_at + 1.second)
                @completed_payload[:data]['documents'].first['url'] = 'https://example.com/second_signed_doc.pdf'
              end
              scan = stage_docuseal_scan!
              scans << scan
              scan.update!(status: :blocked, completed_at: Time.current, last_error_code: 'scan_found')
              DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
            end
          end
        end
        assert_equal 2, scans.map(&:id).uniq.size

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
        assert_response :ok
      end
      assert_equal 'sent', @application.reload.document_signing_status
    end

    test 'oversized provider downloads stop before scan allocation' do
      bytes = '%PDF-1.4'.ljust(ProofUploadFormats.max_bytes(:certification) + 1, 'x')
      mock_successful_docuseal_download(bytes: bytes)
      assert_no_difference ['DocumentScan.count', 'ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'] do
        make_signed_webhook_request(@completed_payload)
        assert_response :ok
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
      make_signed_webhook_request(@declined_payload)
      assert_response :ok

      @application.reload
      assert_equal 'declined', @application.document_signing_status

      event = Event.where(action: 'document_signing_declined').last
      assert_not_nil event
      assert_equal @application, event.auditable
    end

    test 'ignores unknown event types' do
      unknown_payload = {
        event_type: 'form.unknown',
        data: { 'submission_id' => 'sub_123456' }
      }

      make_signed_webhook_request(unknown_payload)
      assert_response :ok
    end

    test 'acknowledges viewed events for an unknown submission ID' do
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

    test 'adds no events for an already signed completion with a document URL' do
      @application.update!(
        document_signing_status: :signed,
        document_signing_document_url: 'https://example.com/signed_doc.pdf'
      )

      assert_no_difference 'Event.count' do
        make_signed_webhook_request(@completed_payload)
        assert_response :ok
      end
    end

    test 'a download exception leaves signing and certification incomplete' do
      @application.update!(medical_certification_status: :requested)
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

      mock_response = mock('http_response')
      mock_response.stubs(:status).returns(mock('status'))
      mock_response.status.stubs(:success?).returns(false)
      mock_response.status.stubs(:code).returns(404)
      mock_response.stubs(:body).returns(HTTP::Response::Body.new(DocumentScanFixtures::ResponseStream.new('')))
      HTTP.stubs(:timeout).returns(HTTP)
      HTTP.stubs(:get).returns(mock_response)

      make_signed_webhook_request(@completed_payload)
      assert_response :ok

      @application.reload
      assert_equal 'sent', @application.document_signing_status
      assert_equal 'requested', @application.medical_certification_status
      assert_not @application.medical_certification.attached?

      event = Event.where(action: 'document_signing_attachment_failed').last
      assert_not_nil event
      assert_equal 'download_failed', event.metadata['failure_reason']
    end

    test 'provider download status codes distinguish permanent rejection from temporary retry' do
      codes = { 401 => :ok, 403 => :ok, 404 => :ok, 410 => :ok, 422 => :ok,
                408 => :service_unavailable, 425 => :service_unavailable, 429 => :service_unavailable,
                500 => :service_unavailable, 502 => :service_unavailable, 503 => :service_unavailable }
      codes.each_with_index do |(code, expected), index|
        @application.update!(document_signing_requested_at: Time.current + index.seconds)
        response = mock("download_#{code}")
        status = mock("download_status_#{code}")
        status.stubs(:success?).returns(false)
        status.stubs(:code).returns(code)
        response.stubs(:status).returns(status)
        response.stubs(:body).returns(HTTP::Response::Body.new(DocumentScanFixtures::ResponseStream.new('')))
        HTTP.stubs(:timeout).returns(HTTP)
        HTTP.stubs(:get).returns(response)

        assert_difference -> { Event.where(auditable: @application, action: 'document_signing_attachment_failed').count }, 1 do
          assert_no_difference ['DocumentScan.count', 'ActiveStorage::Attachment.count'] do
            make_signed_webhook_request(@completed_payload)
            assert_response expected
            travel 6.seconds do
              make_signed_webhook_request(@completed_payload)
              assert_response expected
            end
          end
        end
        event = Event.where(auditable: @application, action: 'document_signing_attachment_failed').order(:id).last!
        assert_equal expected == :service_unavailable, event.metadata['failure_retryable']
        assert_equal "HTTP #{code}", event.metadata['failure_details']
        assert_not_includes event.metadata.to_json, 'https://'
      end
      assert_equal 'sent', @application.reload.document_signing_status
    end

    test 'does not update medical status when document URL is missing' do
      @application.update!(medical_certification_status: :requested)

      payload_without_docs = @completed_payload.deep_dup
      payload_without_docs[:data].delete('documents')

      make_signed_webhook_request(payload_without_docs)
      assert_response :ok

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

    def assert_rejected_completion(headers, body: @completed_payload.to_json)
      assert_no_difference ['DocumentScan.count', 'Event.count', 'Notification.count', 'ActiveStorage::Attachment.count', 'ActiveStorage::Blob.count'] do
        post webhooks_docuseal_medical_certification_path, params: body, headers: headers
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
