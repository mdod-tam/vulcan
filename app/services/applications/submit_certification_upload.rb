# frozen_string_literal: true

module Applications
  class SubmitCertificationUpload < BaseService
    include SecureFormSubmission

    MESSAGE_SCOPE = 'applications.certification_upload.messages'

    attr_reader :application, :secure_request_form, :file

    def self.model_name
      ActiveModel::Name.new(self, nil, 'CertificationUpload')
    end

    def initialize(application:, secure_request_form:, file:)
      super()
      @application = application
      @secure_request_form = secure_request_form
      @file = file
    end

    def call
      return invalid_request_failure unless form_belongs_to_application?
      return inactive_request_failure unless secure_request_form.active_for_public_use?
      return invalid_request_failure unless certification_kind?

      @system_actor = User.system_user
      return failure(message(:attachment_failed)) unless @system_actor

      submit_under_lock(application) do
        # Another path can archive the application after the link was sent.
        unless application.certification_requestable_via_secure_form?
          log_refused_submission
          next failure(message(:no_longer_needed))
        end

        attach_result = accept_certification
        raise_attachment_failure(attach_result[:error]) unless attach_result[:success]

        complete_submission { log_submission(attach_result) }
      end
    end

    private

    def form_belongs_to_application?
      secure_request_form.application_id == application.id
    end

    def certification_kind?
      secure_request_form.kind_certification_upload?
    end

    def request_form = secure_request_form

    def accept_certification
      DisabilityCertificationAttachmentService.accept_submission(
        application: application,
        blob: secure_upload_blob,
        submission_method: :secure_form,
        requested_at: secure_request_form.sent_at,
        admin: @system_actor,
        metadata: {
          secure_request_form_id: secure_request_form.id,
          request_batch_id: secure_request_form.request_batch_id
        }
      )
    end

    def secure_upload_blob
      blob = UploadedDocument.resolve!(file, record: application, name: 'disability_certification',
                                             min_bytes: ProofUploadFormats::SECURE_FORM_MIN_BYTES,
                                             scan_owner: secure_request_form)
      blob.update!(metadata: blob.metadata.merge(secure_upload_metadata))
      blob
    end

    def secure_upload_metadata
      {
        source: 'secure_form',
        secure_request_form_id: secure_request_form.id,
        request_batch_id: secure_request_form.request_batch_id,
        provider_email: secure_request_form.recipient_email
      }
    end

    def log_submission(attach_result)
      AuditEventService.log(
        action: 'cert_submitted_via_secure_form',
        actor: @system_actor,
        auditable: application,
        metadata: secure_upload_metadata.merge(additional_certification_metadata(attach_result))
      )
    end

    # The refusal stands whether or not its audit event is written, as for a refused proof upload.
    def log_refused_submission
      PublicAuditActor.log_audit(
        action: 'cert_secure_submission_refused',
        auditable: application,
        metadata: {
          secure_request_form_id: secure_request_form.id,
          request_batch_id: secure_request_form.request_batch_id,
          reason: 'certification_no_longer_requestable'
        }
      )
    end

    def additional_certification_metadata(attach_result)
      return {} unless attach_result[:placement] == :additional

      {
        retained_as: 'additional_disability_certification',
        additional_disability_certification_blob_id: attach_result[:additional_blob_id],
        retention_reason: attach_result[:retention_reason]
      }
    end

    # The provider is not a User record; the controller sets I18n.locale via
    # with_request_locale before invoking this service.
    def message(key, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **)
    end
  end
end
