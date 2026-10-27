# frozen_string_literal: true

module Webhooks
  # DocuSeal webhook controller for handling document signing events
  # Extends the existing webhook base infrastructure with DocuSeal-specific handling
  class DocusealController < BaseController
    SIGNATURE_TOLERANCE = 5.minutes

    class PermanentIntakeFailure < StandardError
      attr_reader :reason, :details

      def initialize(reason, details)
        @reason = reason
        @details = details
        super(reason)
      end
    end

    def disability_certification
      @system_actor = User.system_user
      return head :service_unavailable unless @system_actor

      event_type = request.request_parameters['event_type']
      data       = request.request_parameters['data']

      case event_type
      when 'form.viewed', 'form.started', 'form.declined' then handle_form_event(event_type, data)
      when 'form.completed'
        return head :service_unavailable if handle_completed(data) == false
      else
        Rails.logger.warn "Unknown DocuSeal event: #{event_type}"
      end

      head :ok
    end

    private

    def valid_payload?
      # Query parameters are not covered by the webhook signature.
      body = request.request_parameters
      body['event_type'].is_a?(String) && body['event_type'].present? && body['data'].is_a?(Hash) && body['data'].present?
    end

    def verify_webhook_signature
      signature = /\A([0-9]+)\.([0-9a-f]{64})\z/.match(request.headers['X-Docuseal-Signature'].to_s)
      if !signature || (Time.current.to_i - signature[1].to_i).abs > SIGNATURE_TOLERANCE
        head :unauthorized
        return false
      end

      expected = compute_signature("#{signature[1]}.#{request.raw_post}")
      unless ActiveSupport::SecurityUtils.secure_compare(signature[2], expected)
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

    def handle_form_event(event_type, data)
      occurred_at = form_event_timestamp(data)
      app = find_application(data['submission_id'])
      return unless app

      app.with_lock do
        next unless app.document_signing_service == 'docuseal' &&
                    app.document_signing_submission_id == data['submission_id'].to_s &&
                    app.document_signing_submitter_id.present? && app.document_signing_submitter_id == data['id'].to_s

        action = event_type.sub('form.', 'document_signing_')
        # DocuSeal's event timestamp survives retries; the signature timestamp and serialized URLs can change.
        key = Digest::SHA256.hexdigest([app.id, app.document_signing_submission_id, app.document_signing_submitter_id,
                                        app.document_signing_requested_at&.utc&.iso8601(6), event_type, occurred_at].to_json)
        operation_id = "docuseal_event_#{key}"
        next if Event.where(auditable: app, action: action).with_metadata('operation_id', operation_id).exists?

        metadata = {
          document_signing_service: 'docuseal', document_signing_submission_id: app.document_signing_submission_id,
          document_signing_submitter_id: app.document_signing_submitter_id, operation_id: operation_id,
          "#{event_type.delete_prefix('form.')}_at" => occurred_at
        }
        metadata[:provider_email] = data['email'] if event_type == 'form.viewed'
        metadata[:decline_reason] = data['decline_reason'] if event_type == 'form.declined'
        advance_signing_status(app, event_type)
        AuditEventService.log(action: action, actor: @system_actor, auditable: app, metadata: metadata)
      end
    end

    def advance_signing_status(app, event_type)
      case event_type
      when 'form.viewed'
        app.update!(document_signing_status: :opened) if app.document_signing_status_sent?
      when 'form.declined'
        app.update!(document_signing_status: :declined) unless app.document_signing_status.in?(%w[signed declined])
      end
    end

    def form_event_timestamp(data)
      %w[id submission_id].each do |field|
        identifier = data[field] if data.respond_to?(:key?)
        raise InvalidPayloadError unless (identifier.is_a?(String) || identifier.is_a?(Integer)) && identifier.present?
      end

      Time.iso8601(request.request_parameters['timestamp']).utc.iso8601(6)
    rescue ArgumentError, TypeError
      raise InvalidPayloadError
    end

    def handle_completed(data)
      app = find_application(data['submission_id'])
      return unless app
      return if app.document_signing_status == 'signed' && app.document_signing_document_url.present?

      context = completion_context(app, data)
      return unless context

      dedup_key = completion_key(context)
      return if permanent_intake_failure?(app, dedup_key)

      existing = DocumentScan.find_by(dedup_key: dedup_key)
      return existing.resume! if existing

      stage_signed_pdf(app, context, dedup_key)
    rescue DocumentScan::SnapshotNotReady
      false # The original webhook is still uploading its snapshot; ask the provider to retry.
    rescue PermanentIntakeFailure => e
      log_attachment_failure(app, e.reason, e.details, context: context, retryable: false)
      true
    rescue UploadedDocument::Refused => e
      log_attachment_failure(app, 'document_refused', e.class.name, context: context, retryable: false)
      true
    rescue StandardError => e
      Rails.logger.error("Document signing intake failed for App ##{app.id} (#{e.class.name})")
      log_attachment_failure(app, 'intake_failed', e.class.name, context: context, retryable: true)
      false
    end

    def completion_context(app, data)
      document = data['documents'].first if data['documents'].is_a?(Array)
      url = document['url'] if document.respond_to?(:key?)

      app.with_lock do
        next unless app.document_signing_submission_id == data['submission_id'].to_s
        next unless app.document_signing_submitter_id.present? && app.document_signing_submitter_id == data['id'].to_s
        next if app.document_signing_status == 'signed' && app.document_signing_document_url.present?

        {
          'application_id' => app.id,
          'submission_id' => app.document_signing_submission_id,
          'submitter_id' => app.document_signing_submitter_id,
          'requested_at' => app.document_signing_requested_at&.utc&.iso8601(6),
          'provider_email' => app.medical_provider_email,
          'actor_id' => @system_actor.id,
          'completed_at' => Time.current.iso8601(6),
          'document_url' => url,
          'audit_url' => data['audit_log_url']
        }
      end
    end

    def completion_key(context)
      Digest::SHA256.hexdigest(context.values_at('application_id', 'submission_id', 'submitter_id', 'requested_at').prepend('docuseal').to_json)
    end

    def permanent_intake_failure?(app, dedup_key)
      Event.where(auditable: app, action: 'document_signing_attachment_failed')
           .with_metadata('docuseal_intake_key', dedup_key).with_metadata('failure_retryable', false).exists?
    end

    def stage_signed_pdf(app, context, dedup_key)
      uri = document_uri!(context['document_url'])
      response = HTTP.timeout(30).get(uri.to_s)
      unless response.status.success?
        code = response.status.code
        if [408, 425, 429].include?(code) || code >= 500
          log_attachment_failure(app, 'download_failed', "HTTP #{code}", context: context, retryable: true)
          return false
        end

        raise PermanentIntakeFailure.new('download_failed', "HTTP #{code}")
      end

      Tempfile.create(['docuseal', '.pdf']) do |file|
        file.binmode
        response.body.each do |chunk|
          if file.size + chunk.bytesize > ProofUploadFormats.max_bytes(:certification)
            raise PermanentIntakeFailure.new('document_too_large', 'Document exceeds the upload limit')
          end

          file.write(chunk)
        end
        file.rewind
        upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "disability_cert_docuseal_#{app.id}.pdf", type: 'application/pdf')
        DocumentScan.stage!(input: upload, purpose: :certification, slot: 'disability_certification',
                            continuation: 'docuseal', context: context, dedup_key: dedup_key)
      end
    ensure
      response.body.connection.close if response
    end

    def document_uri!(url)
      raise PermanentIntakeFailure.new('missing_document_url', 'No document URL provided') if url.blank?
      raise PermanentIntakeFailure.new('invalid_document_url', 'Document URL is malformed') unless url.is_a?(String)

      uri = URI.parse(url)
      valid = uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
      raise PermanentIntakeFailure.new('invalid_document_url', 'Document URL must use HTTPS') unless valid

      allowed_hosts = ['docuseal.com', 'docuseal.eu', URI.parse(::Docuseal.url).host].compact.map(&:downcase)
      raise PermanentIntakeFailure.new('invalid_document_url', 'Document URL must use a DocuSeal host') unless uri.host.downcase.in?(allowed_hosts)

      uri
    rescue URI::InvalidURIError
      raise PermanentIntakeFailure.new('invalid_document_url', 'Document URL is malformed')
    end

    def log_attachment_failure(app, reason, details, context:, retryable:)
      return unless context

      dedup_key = completion_key(context)
      operation_id = "docuseal_intake_#{dedup_key}_#{reason}_#{retryable}"
      app.with_lock do
        next unless app.document_signing_submission_id == context['submission_id'] &&
                    app.document_signing_submitter_id == context['submitter_id'] &&
                    app.document_signing_requested_at&.utc&.iso8601(6) == context['requested_at'] &&
                    app.medical_provider_email == context['provider_email']
        next if Event.where(auditable: app, action: 'document_signing_attachment_failed')
                     .with_metadata('operation_id', operation_id).with_metadata('failure_reason', reason).exists?

        AuditEventService.log(
          action: 'document_signing_attachment_failed', actor: @system_actor, auditable: app,
          metadata: {
            document_signing_service: 'docuseal', document_signing_submission_id: context['submission_id'],
            operation_id: operation_id, docuseal_intake_key: dedup_key, failure_reason: reason, failure_details: details,
            failure_retryable: retryable, failed_at: Time.current.iso8601
          }
        )
      end
    end
  end
end
