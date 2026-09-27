# frozen_string_literal: true

module Applications
  class SubmitCertificationUpload < BaseService
    include SecureFormSubmission

    MESSAGE_SCOPE = 'applications.certification_upload.messages'

    attr_reader :application, :medical_provider_secure_request_form, :file

    def self.model_name
      ActiveModel::Name.new(self, nil, 'CertificationUpload')
    end

    def initialize(application:, medical_provider_secure_request_form:, file:)
      super()
      @application = application
      @medical_provider_secure_request_form = medical_provider_secure_request_form
      @file = file
    end

    def call
      return invalid_request_failure unless form_belongs_to_application?
      return inactive_request_failure unless medical_provider_secure_request_form.active_for_public_use?
      return invalid_request_failure unless certification_kind?
      return validation_failure unless file_valid?

      result = nil

      ApplicationRecord.transaction do
        # Lock the application before the form, in the same order as issuance.
        application.lock!
        medical_provider_secure_request_form.lock!
        unless medical_provider_secure_request_form.active_for_public_use?
          result = inactive_request_failure
          next
        end

        attach_result = accept_certification
        raise_attachment_failure(attach_result[:error]) unless attach_result[:success]

        medical_provider_secure_request_form.mark_submitted!
        log_submission(attach_result)
        result = success(message(:submitted))
      end

      result
    rescue AttachmentFailure => e
      failure(e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { errors: e.record.errors })
    end

    private

    def form_belongs_to_application?
      medical_provider_secure_request_form.application_id == application.id
    end

    def certification_kind?
      medical_provider_secure_request_form.kind_certification_upload?
    end

    def request_form = medical_provider_secure_request_form

    def accept_certification
      MedicalCertificationAttachmentService.accept_submission(
        application: application,
        blob: create_secure_upload_blob,
        submission_method: :secure_form,
        requested_at: medical_provider_secure_request_form.sent_at,
        admin: User.system_user,
        metadata: {
          medical_provider_secure_request_form_id: medical_provider_secure_request_form.id,
          request_batch_id: medical_provider_secure_request_form.request_batch_id
        }
      )
    end

    def create_secure_upload_blob
      io = upload_io
      io.rewind if io.respond_to?(:rewind)

      ActiveStorage::Blob.create_and_upload!(
        io: io,
        filename: upload_filename,
        content_type: upload_content_type,
        metadata: secure_upload_metadata
      )
    end

    def upload_io
      file.respond_to?(:tempfile) ? file.tempfile : file
    end

    def upload_filename
      if file.respond_to?(:original_filename)
        file.original_filename
      elsif file.respond_to?(:filename)
        file.filename
      else
        'medical_certification_upload'
      end
    end

    def upload_content_type
      file.content_type if file.respond_to?(:content_type)
    end

    def secure_upload_metadata
      {
        source: 'secure_form',
        medical_provider_secure_request_form_id: medical_provider_secure_request_form.id,
        request_batch_id: medical_provider_secure_request_form.request_batch_id,
        provider_email: medical_provider_secure_request_form.provider_email
      }
    end

    def log_submission(attach_result)
      AuditEventService.log(
        action: 'cert_submitted_via_secure_form',
        actor: User.system_user,
        auditable: application,
        metadata: secure_upload_metadata.merge(additional_certification_metadata(attach_result))
      )
    end

    def additional_certification_metadata(attach_result)
      return {} unless attach_result[:placement] == :additional

      {
        retained_as: 'additional_medical_certification',
        additional_medical_certification_blob_id: attach_result[:additional_blob_id],
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
