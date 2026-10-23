# frozen_string_literal: true

module Webhooks
  # DocuSeal webhook controller for handling document signing events
  # Extends the existing webhook base infrastructure with DocuSeal-specific handling
  class DocusealController < BaseController
    def medical_certification
      @system_actor = User.system_user
      return head :service_unavailable unless @system_actor

      event_type = params[:event_type]
      data       = params[:data] || {}

      case event_type
      when 'form.viewed'   then handle_viewed(data)
      when 'form.started'  then handle_started(data)
      when 'form.completed'
        return head :service_unavailable if handle_completed(data) == false
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
        actor: @system_actor,
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
        actor: @system_actor,
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
      return if app.document_signing_status == 'signed' && app.document_signing_document_url.present?

      context = completion_context(app, data)
      return false unless context

      dedup_key = Digest::SHA256.hexdigest(['docuseal', app.id, context['submission_id'], context['document_url']].join(':'))
      if (existing = DocumentScan.find_by(dedup_key: dedup_key))
        DocumentScan.stage!(input: nil, purpose: :certification, slot: 'medical_certification',
                            continuation: 'docuseal', context: context, dedup_key: dedup_key)
        return existing
      end

      stage_signed_pdf(app, context, dedup_key) || false
    rescue DocumentScans::Stager::SnapshotNotReady
      false # The original webhook is still uploading its snapshot; ask the provider to retry.
    rescue StandardError => e
      Rails.logger.error("Document signing intake failed for App ##{app.id} (#{e.class.name})")
      log_attachment_failure(app, 'intake_failed', e.class.name)
      false
    end

    def handle_declined(data)
      app = find_application(data['submission_id'])
      return unless app

      app.update!(document_signing_status: :declined)
      AuditEventService.log(
        action: 'document_signing_declined',
        actor: @system_actor,
        auditable: app,
        metadata: {
          document_signing_service: 'docuseal',
          document_signing_submission_id: data['submission_id'],
          decline_reason: data['decline_reason'],
          declined_at: Time.current.iso8601
        }
      )
    end

    def completion_context(app, data)
      documents = data['documents'] || []
      url = documents.first && documents.first['url']
      if url.blank?
        log_attachment_failure(app, 'missing_document_url', 'No document URL provided in webhook payload')
        return nil
      end

      app.with_lock do
        next unless app.document_signing_submission_id == data['submission_id'].to_s
        next if app.document_signing_status == 'signed' && app.document_signing_document_url.present?

        {
          'application_id' => app.id,
          'submission_id' => app.document_signing_submission_id,
          'requested_at' => app.document_signing_requested_at&.iso8601(6),
          'provider_email' => app.medical_provider_email,
          'actor_id' => @system_actor.id,
          'completed_at' => Time.current.iso8601(6),
          'document_url' => url,
          'audit_url' => data['audit_log_url']
        }
      end
    end

    def stage_signed_pdf(app, context, dedup_key)
      uri = URI.parse(context.fetch('document_url'))
      raise ArgumentError, 'Document URL must use HTTPS' unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?

      response = HTTP.timeout(30).get(uri.to_s)
      unless response.status.success?
        log_attachment_failure(app, 'download_failed', "HTTP #{response.status.code}")
        return nil
      end

      Tempfile.create(['docuseal', '.pdf']) do |file|
        file.binmode
        response.body.each do |chunk|
          raise IOError, 'Document exceeds the upload limit' if file.size + chunk.bytesize > ProofUploadFormats.max_bytes(:certification)

          file.write(chunk)
        end
        file.rewind
        upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "medical_cert_docuseal_#{app.id}.pdf", type: 'application/pdf')
        DocumentScan.stage!(input: upload, purpose: :certification, slot: 'medical_certification',
                            continuation: 'docuseal', context: context, dedup_key: dedup_key)
      end
    ensure
      response.body.connection.close if response
    end

    def log_attachment_failure(app, reason, details)
      AuditEventService.log(
        action: 'document_signing_attachment_failed',
        actor: @system_actor,
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
