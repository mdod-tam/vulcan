# frozen_string_literal: true

module DocumentSigning
  # Service to handle document signing submissions via DocuSeal or other providers
  # Reuses existing service patterns and audit mechanisms
  class SubmissionService < BaseService
    attr_reader :service_type

    def initialize(application:, actor:, service: 'docuseal')
      super()
      @application = application
      @actor = actor
      @service_type = service
    end

    def call
      return failure('Medical provider email is required') if @application.medical_provider_email.blank?
      return failure('Medical provider name is required')  if @application.medical_provider_name.blank?
      return failure('Actor is required') if @actor.blank?

      # Prevent duplicate requests within 30 seconds
      if @application.document_signing_requested_at.present? &&
         @application.document_signing_requested_at > 30.seconds.ago
        return failure('Request sent too recently. Please wait before sending another.')
      end

      submission = create_submission!
      submitter  = submission['submitters']&.first

      @application.with_lock do
        @application.update!(
          document_signing_service: @service_type,
          document_signing_submission_id: submission['id'].to_s,
          document_signing_submitter_id: submitter&.dig('id').to_s,
          document_signing_status: :sent,
          document_signing_requested_at: Time.current,
          # Also update medical certification tracking
          medical_certification_status: :requested,
          medical_certification_requested_at: Time.current
        )

        # Use increment! for atomic counter updates
        @application.increment!(:document_signing_request_count)
        @application.increment!(:medical_certification_request_count)
      end

      AuditEventService.log(
        action: 'document_signing_request_sent',
        actor: @actor,
        auditable: @application,
        metadata: {
          document_signing_service: @service_type,
          document_signing_submission_id: submission['id'],
          provider_name: @application.medical_provider_name,
          provider_email: @application.medical_provider_email,
          submission_method: 'document_signing'
        }
      )

      success('Document signing request created', submission)
    rescue StandardError => e
      log_error(e, application_id: @application.id)
      failure("Failed to create document signing request: #{e.message}")
    end

    private

    def create_submission!
      data = {
        name: "Medical Certification - App #{@application.id}",
        submitters: [{
          role: 'Medical Provider',
          email: @application.medical_provider_email,
          name: @application.medical_provider_name
        }],
        send_email: true,
        completed_redirect_url: Rails.application.routes.url_helpers.admin_application_url(
          @application,
          host: Rails.application.config.action_mailer.default_url_options[:host]
        )
      }

      # Use DocuSeal gem to create submission
      # Note: This assumes template-based submission. If using HTML, the implementation
      # would call ::Docuseal.create_submission_from_html instead
      ::Docuseal.create_submission(data)
    end
  end
end
