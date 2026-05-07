# frozen_string_literal: true

module Webhooks
  # DocuSeal webhook controller for handling document signing events
  # Extends the existing webhook base infrastructure with DocuSeal-specific handling
  class DocusealController < BaseController
    def medical_certification
      event_type = params[:event_type]
      data       = params[:data] || {}

      case event_type
      when 'form.viewed'   then handle_viewed(data)
      when 'form.started'  then handle_started(data)
      when 'form.completed' then handle_completed(data)
      when 'form.declined' then handle_declined(data)
      else
        Rails.logger.warn "Unknown DocuSeal event: #{event_type}"
      end

      head :ok
    end

    private

    def valid_payload?
      params[:event_type].present? && params[:data].present?
    end

    # Override to handle DocuSeal-specific signature headers
    def verify_webhook_signature
      # Try standard X-Webhook-Signature first
      signature = request.headers['X-Webhook-Signature']

      # Fallback to DocuSeal-specific header if present
      signature ||= request.headers['X-DocuSeal-Signature']

      if signature.nil?
        head :unauthorized
        return false
      end

      data = request.raw_post

      # Handle sha256= prefix if present
      signature = signature.sub(/\Asha256=/, '') if signature.start_with?('sha256=')

      expected = compute_signature(data)

      unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)
        head :unauthorized
        return false
      end

      true
    end

    def find_application(submission_id)
      return nil if submission_id.blank?

      Application.find_by(
        document_signing_submission_id: submission_id.to_s,
        document_signing_service: 'docuseal'
      )
    end

    def handle_viewed(data)
      app = find_application(data['submission_id'])
      return unless app

      app.update!(document_signing_status: :opened)
      AuditEventService.log(
        action: 'document_signing_viewed',
        actor: User.system_user,
        auditable: app,
        metadata: {
          document_signing_service: 'docuseal',
          document_signing_submission_id: data['submission_id'],
          provider_email: data['email'],
          viewed_at: Time.current.iso8601
        }
      )
    end

    def handle_started(data)
      app = find_application(data['submission_id'])
      return unless app

      AuditEventService.log(
        action: 'document_signing_started',
        actor: User.system_user,
        auditable: app,
        metadata: {
          document_signing_service: 'docuseal',
          document_signing_submission_id: data['submission_id'],
          started_at: Time.current.iso8601
        }
      )
    end

    def handle_completed(data)
      app = find_application(data['submission_id'])
      return unless app

      # Idempotency: skip if already processed for this submission (same URL check happens in attach)
      return if app.document_signing_status == 'signed' && app.document_signing_document_url.present?

      current_status = app.medical_certification_status.to_s
      retained_additional_blob_id = nil

      if retain_docuseal_as_additional?(app, current_status)
        # A MAT secure upload already supplied the certification. Keep that
        # first received document as primary, while retaining the later DocuSeal
        # PDF separately for admin review/comparison.
        retained_additional_blob_id = attach_additional_signed_pdf(app, data)
        app.update!(
          document_signing_status: :signed,
          document_signing_signed_at: Time.current
        )
      elsif current_status == 'approved'
        # Discard the incoming file; keep existing approved certification
        url = signed_pdf_url(app, data)
        app.update!(
          document_signing_status: :signed,
          document_signing_signed_at: Time.current,
          document_signing_audit_url: data['audit_log_url'],
          document_signing_document_url: url.presence || app.document_signing_document_url
        )
      else
        # Attach and mark as received when no current secure-upload primary
        # certification must be protected from a late DocuSeal completion.
        attach_signed_pdf(app, data)
        update_attrs = {
          document_signing_status: :signed,
          document_signing_signed_at: Time.current
        }
        app.update!(update_attrs)
      end

      AuditEventService.log(
        action: 'document_signing_completed',
        actor: User.system_user,
        auditable: app,
        metadata: {
          document_signing_service: 'docuseal',
          document_signing_submission_id: data['submission_id'],
          completed_at: Time.current.iso8601,
          provider_email: data['email']
        }.merge(document_signing_completion_metadata(retained_additional_blob_id))
      )
    end

    def retain_docuseal_as_additional?(app, current_status)
      current_status.in?(%w[received approved rejected]) && secure_certification_upload_previously_received?(app)
    end

    def secure_certification_upload_previously_received?(app)
      Event.exists?(auditable: app, action: 'cert_submitted_via_secure_form')
    end

    def document_signing_completion_metadata(retained_additional_blob_id)
      return {} if retained_additional_blob_id.blank?

      {
        retained_as: 'additional_medical_certification',
        additional_medical_certification_blob_id: retained_additional_blob_id
      }
    end

    def handle_declined(data)
      app = find_application(data['submission_id'])
      return unless app

      app.update!(document_signing_status: :declined)
      AuditEventService.log(
        action: 'document_signing_declined',
        actor: User.system_user,
        auditable: app,
        metadata: {
          document_signing_service: 'docuseal',
          document_signing_submission_id: data['submission_id'],
          decline_reason: data['decline_reason'],
          declined_at: Time.current.iso8601
        }
      )
    end

    # Attempts to download and attach the signed PDF from DocuSeal.
    # Returns true on success (including idempotent skip), false on failure.
    def attach_signed_pdf(app, data)
      url = signed_pdf_url(app, data)
      return false if url.blank?

      # Idempotency: skip if same URL already stored (consider this a success)
      return true if app.document_signing_document_url == url

      blob = signed_pdf_blob(app, data, url, filename: "medical_cert_docuseal_#{app.id}.pdf")
      return false unless blob

      result = MedicalCertificationAttachmentService.attach_certification(
        application: app,
        blob_or_file: blob,
        status: :received,
        admin: User.system_user,
        submission_method: :docuseal,
        metadata: {
          document_signing_service: 'docuseal',
          document_signing_submission_id: app.document_signing_submission_id,
          document_signing_document_url: url,
          document_signing_audit_url: data['audit_log_url']
        }
      )
      return false unless result[:success]

      persist_document_signing_urls!(app, data, url)
      true
    rescue StandardError => e
      Rails.logger.error "Document signing download/attach failed for App ##{app.id}: #{e.message}"
      Rails.logger.error "Payload data keys: #{data.keys.join(', ')}" if data.respond_to?(:keys)
      log_attachment_failure(app, 'exception', e.message)
      false
    end

    def attach_additional_signed_pdf(app, data)
      url = signed_pdf_url(app, data)
      return if url.blank?

      existing_attachment = additional_signed_pdf_attachment(app, url)
      return existing_attachment.blob_id if existing_attachment

      blob = signed_pdf_blob(app, data, url, filename: "medical_cert_docuseal_additional_#{app.id}.pdf")
      return unless blob

      app.additional_medical_certifications.attach(blob)
      persist_document_signing_urls!(app, data, url)
      blob.id
    rescue StandardError => e
      Rails.logger.error "Document signing download/attach failed for App ##{app.id}: #{e.message}"
      Rails.logger.error "Payload data keys: #{data.keys.join(', ')}" if data.respond_to?(:keys)
      log_attachment_failure(app, 'exception', e.message)
      nil
    end

    def signed_pdf_url(app, data)
      documents = data['documents'] || []
      url = documents.first && documents.first['url']
      return url if url.present?

      Rails.logger.warn "DocuSeal webhook: missing document URL. Available keys: #{data.keys.join(', ')}"
      log_attachment_failure(app, 'missing_document_url', 'No document URL provided in webhook payload')
      nil
    end

    def signed_pdf_blob(app, data, url, filename:)
      response = HTTP.timeout(30).get(url)
      unless response.status.success?
        log_attachment_failure(app, 'download_failed', "HTTP #{response.status.code}")
        return nil
      end

      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(response.body.to_s),
        filename: filename,
        content_type: 'application/pdf',
        metadata: {
          source: 'docuseal',
          document_signing_document_url: url,
          document_signing_audit_url: data['audit_log_url']
        }
      )
    end

    def additional_signed_pdf_attachment(app, url)
      app.additional_medical_certifications.attachments.find do |attachment|
        attachment.blob.metadata['document_signing_document_url'] == url
      end
    end

    def persist_document_signing_urls!(app, data, url)
      app.update!(
        document_signing_audit_url: data['audit_log_url'],
        document_signing_document_url: url
      )
    end

    def log_attachment_failure(app, reason, details)
      AuditEventService.log(
        action: 'document_signing_attachment_failed',
        actor: User.system_user,
        auditable: app,
        metadata: {
          document_signing_service: 'docuseal',
          document_signing_submission_id: app.document_signing_submission_id,
          failure_reason: reason,
          failure_details: details,
          failed_at: Time.current.iso8601
        }
      )
    end
  end
end
