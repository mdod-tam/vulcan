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

      case current_status
      when 'approved'
        # Discard the incoming file; keep existing approved certification
        app.update!(
          document_signing_status: :signed,
          document_signing_signed_at: Time.current
        )
      when 'rejected'
        # Allow resubmission: attach and move back to received for review
        attach_signed_pdf(app, data)
        app.update!(
          document_signing_status: :signed,
          document_signing_signed_at: Time.current,
          medical_certification_status: :received
        )
      else
        # requested/received/not_requested → attach and mark as received (admin will review)
        attach_signed_pdf(app, data)
        medical_status_update = {}
        medical_status_update[:medical_certification_status] = :received unless current_status == 'received'
        app.update!(
          {
            document_signing_status: :signed,
            document_signing_signed_at: Time.current
          }.merge(medical_status_update)
        )
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
        }
      )
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

    def attach_signed_pdf(app, data)
      documents = data['documents'] || []
      url = documents.first && documents.first['url']

      unless url.present?
        Rails.logger.warn "DocuSeal webhook: missing document URL. Available keys: #{data.keys.join(', ')}"
        return
      end

      # Idempotency: skip if same URL already stored
      return if app.document_signing_document_url == url

      response = HTTP.timeout(30).get(url)
      return unless response.status.success?

      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(response.body.to_s),
        filename: "medical_cert_docuseal_#{app.id}.pdf",
        content_type: 'application/pdf'
      )

      app.medical_certification.attach(blob)
      app.update!(
        document_signing_audit_url: data['audit_log_url'],
        document_signing_document_url: url
      )
    rescue StandardError => e
      Rails.logger.error "Document signing download/attach failed for App ##{app.id}: #{e.message}"
      Rails.logger.error "Payload data keys: #{data.keys.join(', ')}" if data.respond_to?(:keys)
    end
  end
end
