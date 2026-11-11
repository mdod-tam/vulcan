# frozen_string_literal: true

require 'test_helper'

class DocumentSigningWorkflowTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  include AuthenticationTestHelper
  include ConcurrencyTestHelper

  setup do
    Current.reset
    @original_scan_ids = DocumentScan.order(:id).pluck(:id)
    @existing_system_actor = PublicAuditActor.system_audit_actor
    @configured_system_actor = ensure_system_audit_actor!
    @admin = create(:admin)
    @original_controls = FeatureFlag.where(name: EmailDelivery::CONTROL_NAMES).to_h do |control|
      [control.name, control.slice(:enabled, :delivery_generation, :updated_at)]
    end
    EmailDelivery::CONTROL_NAMES.each do |name|
      FeatureFlag.find_or_create_by!(name: name) { |flag| flag.enabled = true }
      EmailDelivery::ControlWriter.set(name: name, enabled: true, actor: @admin, operation_id: SecureRandom.uuid)
    end
    sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)

    # Webhook audit events require a system actor.
    @system_user = create(:admin, email: 'system@example.com')
    User.stubs(:system_user).returns(@system_user)

    @application = create(:application, :in_progress,
                          application_date: Date.current,
                          certifying_professional_email: 'doctor@example.com',
                          certifying_professional_name: 'Dr. Jane Smith')

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

  teardown do
    scans = application_docuseal_scans
    scan_ids = scans.map(&:id)
    blob_ids = scans.map(&:blob_id)
    blob_ids.concat(ActiveStorage::Attachment.where(record: @application).pluck(:blob_id)) if @application
    # Restore fixture state; toggling back on preserves a generation raised by the test.
    EmailDelivery::CONTROL_NAMES.each do |name|
      if @original_controls.key?(name)
        control = FeatureFlag.find_by!(name: name)
        control.update_columns(@original_controls.fetch(name))
        assert_equal @original_controls.fetch(name), control.reload.slice(:enabled, :delivery_generation, :updated_at)
      else
        FeatureFlag.find_by(name: name)&.destroy!
        assert_not FeatureFlag.exists?(name: name)
      end
    end
    cleanup_duplicate_review_test_data!(@application&.user, @admin, @system_user)
    cleanup_duplicate_review_test_data!(@configured_system_actor) unless @existing_system_actor
    ActiveStorage::Blob.where(id: blob_ids.uniq).find_each(&:purge)
    assert_empty DocumentScan.where(id: scan_ids), 'This workflow must remove its provider snapshots'
    assert_empty ActiveStorage::Blob.where(id: blob_ids.uniq), 'This workflow must remove its stored file bytes'
    assert_equal @original_scan_ids, DocumentScan.order(:id).pluck(:id), 'Workflow cleanup must preserve other scans and leave none of its own'
    Current.reset
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
    assert_equal 'requested', @application.disability_certification_status

    # Viewed webhook
    viewed_payload = {
      event_type: 'form.viewed',
      timestamp: Time.current.utc.iso8601(6),
      data: {
        'id' => 'submitter_789',
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com'
      }
    }

    signature = compute_webhook_signature(viewed_payload.to_json)
    post webhooks_docuseal_disability_certification_path,
         params: viewed_payload,
         headers: { 'X-Docuseal-Signature' => signature },
         as: :json

    assert_response :ok
    @application.reload
    assert_equal 'opened', @application.document_signing_status

    # Started webhook
    started_payload = {
      event_type: 'form.started',
      timestamp: Time.current.utc.iso8601(6),
      data: {
        'id' => 'submitter_789',
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com'
      }
    }

    signature = compute_webhook_signature(started_payload.to_json)
    post webhooks_docuseal_disability_certification_path,
         params: started_payload,
         headers: { 'X-Docuseal-Signature' => signature },
         as: :json

    assert_response :ok
    # The started webhook records an event without a status change.

    # Completed webhook
    completed_payload = {
      event_type: 'form.completed',
      data: {
        'id' => 'submitter_789',
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com',
        'documents' => [
          {
            'url' => 'https://docuseal.com/signed_doc.pdf',
            'filename' => 'disability_cert.pdf'
          }
        ],
        'audit_log_url' => 'https://docuseal.com/audit_log'
      }
    }

    mock_docuseal_download

    signature = compute_webhook_signature(completed_payload.to_json)
    post webhooks_docuseal_disability_certification_path,
         params: completed_payload,
         headers: { 'X-Docuseal-Signature' => signature },
         as: :json

    assert_response :ok
    scan = assert_pending_scan(certification_status: 'requested', signing_status: 'opened')
    complete_scan!(scan)
    @application.reload
    assert_equal 'signed', @application.document_signing_status
    assert_equal 'received', @application.disability_certification_status
    assert_not_nil @application.document_signing_signed_at
    assert @application.disability_certification.attached?
    assert_equal 'https://docuseal.com/audit_log', @application.document_signing_audit_url

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
      timestamp: Time.current.utc.iso8601(6),
      data: {
        'id' => 'submitter_789',
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com'
      }
    }

    signature = compute_webhook_signature(declined_payload.to_json)
    post webhooks_docuseal_disability_certification_path,
         params: declined_payload,
         headers: { 'X-Docuseal-Signature' => signature },
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
    @application.update!(disability_certification_status: :rejected)
    ApplicationStatusChange.create!(application: @application, user: @admin, from_status: 'received', to_status: 'rejected',
                                    change_type: 'disability_certification', changed_at: 2.days.ago)
    @application.update!(
      document_signing_service: 'docuseal',
      document_signing_submission_id: 'sub_123456',
      document_signing_submitter_id: 'submitter_789',
      document_signing_status: :sent,
      document_signing_requested_at: 1.day.ago
    )

    completed_payload = {
      event_type: 'form.completed',
      data: {
        'id' => 'submitter_789',
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com',
        'documents' => [
          {
            'url' => 'https://docuseal.com/signed_doc.pdf',
            'filename' => 'disability_cert.pdf'
          }
        ],
        'audit_log_url' => 'https://docuseal.com/audit_log'
      }
    }

    mock_docuseal_download

    signature = compute_webhook_signature(completed_payload.to_json)
    post webhooks_docuseal_disability_certification_path,
         params: completed_payload,
         headers: { 'X-Docuseal-Signature' => signature },
         as: :json

    assert_response :ok
    scan = assert_pending_scan(certification_status: 'rejected', signing_status: 'sent')
    complete_scan!(scan)
    @application.reload

    assert_equal 'received', @application.disability_certification_status
    assert_equal 'signed', @application.document_signing_status
    assert @application.disability_certification.attached?
  end

  test 'document signing workflow retains the approved primary and files a clean completion as additional' do
    file = Rack::Test::UploadedFile.new(file_fixture('disability_certification_valid.pdf'), 'application/pdf')
    primary = scanned_upload(file, user: @admin, purpose: :certification, slot: 'disability_certification')
    file.tempfile.close
    @application.disability_certification.attach(primary)
    @application.update!(disability_certification_status: :approved)
    @application.update!(
      document_signing_service: 'docuseal',
      document_signing_submission_id: 'sub_123456',
      document_signing_submitter_id: 'submitter_789',
      document_signing_status: :sent
    )

    completed_payload = {
      event_type: 'form.completed',
      data: {
        'id' => 'submitter_789',
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com',
        'documents' => [
          {
            'url' => 'https://docuseal.com/signed_doc.pdf'
          }
        ],
        'audit_log_url' => 'https://docuseal.com/audit_log'
      }
    }

    mock_docuseal_download
    signature = compute_webhook_signature(completed_payload.to_json)
    post webhooks_docuseal_disability_certification_path,
         params: completed_payload,
         headers: { 'X-Docuseal-Signature' => signature },
         as: :json

    assert_response :ok
    scan = assert_pending_scan(certification_status: 'approved', signing_status: 'sent', primary: primary)
    assert_difference -> { @application.additional_disability_certifications.attachments.count }, 1 do
      complete_scan!(scan)
    end
    @application.reload

    assert_equal 'approved', @application.disability_certification_status
    assert_equal 'signed', @application.document_signing_status
    assert_equal primary.id, @application.disability_certification.blob.id
    assert @application.additional_disability_certifications.blobs.exists?(id: scan.blob_id)
    event = Event.where(action: 'document_signing_completed', auditable: @application).sole
    assert_equal 'additional_disability_certification', event.metadata.fetch('retained_as')
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

  test 'a late certification stop keeps a DocuSeal request accepted in the same second' do
    Docuseal.stubs(:create_submission).returns({ 'id' => 'sub-1', 'submitters' => [{ 'id' => 'subm-1' }] })
    EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.allowed)
                         .then.returns(EmailDelivery::Decision.allowed)
                         .then.returns(EmailDelivery::Decision.suppressed(:global_disabled))
    service_class = Class.new(Applications::RequestCertificationUpload) do
      private

      # Another admin sends a DocuSeal request between preparation and the final check.
      def deliver_request_email!(request_form, raw_token)
        result = DocumentSigning::SubmissionService.new(application: application.reload, actor: actor).call
        raise "DocuSeal request failed: #{result.message}" unless result.success?

        super
      end
    end

    travel_to Time.current.change(usec: 100) do
      service_class.new(application: @application, actor: @admin, deliver_email: true).call
    end

    @application.reload
    assert @application.document_signing_status_sent?
    assert @application.disability_certification_status_requested?
    assert_not_nil @application.disability_certification_requested_at
  end

  private

  def mock_docuseal_download
    response = mock('http_response')
    response.stubs(:status).returns(mock('status', success?: true))
    response.stubs(:body).returns(HTTP::Response::Body.new(DocumentScanFixtures::ResponseStream.new(file_fixture('disability_certification_valid.pdf').binread)))
    HTTP.stubs(:timeout).returns(HTTP)
    HTTP.stubs(:get).returns(response)
  end

  def assert_pending_scan(certification_status:, signing_status:, primary: nil)
    scan = application_docuseal_scans.sole
    assert_predicate scan, :pending?
    assert_empty scan.blob.attachments
    @application.reload
    assert_equal primary&.id, @application.disability_certification.blob&.id
    assert_equal certification_status, @application.disability_certification_status
    assert_equal signing_status, @application.document_signing_status
    assert_not Event.exists?(action: 'document_signing_completed', auditable: @application)
    scan
  end

  def application_docuseal_scans
    return [] unless @application

    # Context is encrypted; scope by its decrypted application identity.
    DocumentScan.where(continuation: 'docuseal').select do |scan|
      scan.context['application_id'].to_s == @application.id.to_s
    end
  end

  def complete_scan!(scan)
    scan.update!(status: :clean, completed_at: Time.current)
    DocumentSigning::AcceptScannedDocumentJob.perform_now(scan.id)
  end

  def compute_webhook_signature(payload)
    timestamp = Time.current.to_i
    digest = OpenSSL::HMAC.hexdigest('SHA256', @webhook_secret, "#{timestamp}.#{payload}")
    "#{timestamp}.#{digest}"
  end
end
