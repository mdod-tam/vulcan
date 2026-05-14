# frozen_string_literal: true

module Applications
  class SubmitCertificationUpload < BaseService
    MESSAGE_SCOPE = 'applications.certification_upload.messages'
    class AttachmentFailure < StandardError; end

    attr_reader :application, :medical_provider_secure_request_form, :file, :form_errors

    delegate :model_name, to: :class

    def self.human_attribute_name(attribute, *_args)
      attribute.to_s.humanize
    end

    def self.lookup_ancestors
      [self]
    end

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
        medical_provider_secure_request_form.with_lock do
          medical_provider_secure_request_form.reload
          unless medical_provider_secure_request_form.active_for_public_use?
            result = inactive_request_failure
            next
          end

          attach_result = attach_certification_for_current_primary
          raise AttachmentFailure, attach_result[:error]&.message || message(:attachment_failed) unless attach_result[:success]

          medical_provider_secure_request_form.mark_submitted!
          log_submission(additional_blob_id: attach_result[:additional_blob_id])
          result = success(message(:submitted))
        end
      end

      result
    rescue AttachmentFailure => e
      failure(e.message.presence || message(:attachment_failed))
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { errors: e.record.errors })
    end

    def read_attribute_for_validation(attribute)
      public_send(attribute)
    end

    private

    def form_belongs_to_application?
      medical_provider_secure_request_form.application_id == application.id
    end

    def certification_kind?
      medical_provider_secure_request_form.kind_certification_upload?
    end

    def invalid_request_failure
      failure(message(:invalid_request))
    end

    def inactive_request_failure
      key = if medical_provider_secure_request_form.submitted?
              :already_submitted
            elsif medical_provider_secure_request_form.revoked?
              :revoked
            elsif medical_provider_secure_request_form.expired?
              :expired
            else
              :invalid_request
            end

      failure(message(key))
    end

    def validation_failure
      failure(message(:validation_failed), { errors: form_errors })
    end

    def file_valid?
      @form_errors = ActiveModel::Errors.new(self)
      validate_file
      form_errors.blank?
    end

    def validate_file
      ProofAttachmentValidator.validate!(file)
    rescue ProofAttachmentValidator::ValidationError => e
      form_errors.add(:file, e.error_type, message: validation_message(e))
    end

    def attach_certification
      actor = User.system_user

      # MedicalCertificationAttachmentService.attach_certification internally calls
      # update_certification_status_only, which uses update_columns to bypass
      # validations and callbacks. This is the existing service contract — do not
      # build callback-dependent cert-status logic that assumes after_save fires
      # after this call.
      MedicalCertificationAttachmentService.attach_certification(
        application: application,
        blob_or_file: file,
        status: :received,
        admin: actor,
        submission_method: :secure_form,
        metadata: {
          medical_provider_secure_request_form_id: medical_provider_secure_request_form.id,
          request_batch_id: medical_provider_secure_request_form.request_batch_id
        }
      )
    end

    def attach_certification_for_current_primary
      if retain_secure_upload_as_additional?
        attach_additional_certification
      else
        attach_certification
      end
    end

    def retain_secure_upload_as_additional?
      application.medical_certification.attached? &&
        docuseal_primary_certification?
    end

    def docuseal_primary_certification?
      return true if application.medical_certification.blob.metadata['source'] == 'docuseal'
      return true if docuseal_certification_status_change?

      document_signing_completed? && !secure_certification_upload_previously_received?
    end

    def docuseal_certification_status_change?
      ApplicationStatusChange
        .where(application: application, change_type: 'medical_certification')
        .exists?(["metadata->>'submission_method' = ?", 'docuseal'])
    end

    def document_signing_completed?
      application.document_signing_status_signed? ||
        Event.exists?(auditable: application, action: 'document_signing_completed')
    end

    def secure_certification_upload_previously_received?
      Event.exists?(auditable: application, action: 'cert_submitted_via_secure_form')
    end

    def attach_additional_certification
      blob = create_secure_upload_blob
      application.additional_medical_certifications.attach(blob)

      {
        success: application.additional_medical_certifications.attachments.any? { |attachment| attachment.blob_id == blob.id },
        additional_blob_id: blob.id
      }
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

    def log_submission(additional_blob_id: nil)
      actor = User.system_user

      AuditEventService.log(
        action: 'cert_submitted_via_secure_form',
        actor: actor,
        auditable: application,
        metadata: secure_upload_metadata.merge(additional_certification_metadata(additional_blob_id))
      )
    end

    def additional_certification_metadata(additional_blob_id)
      return {} if additional_blob_id.blank?

      {
        retained_as: 'additional_medical_certification',
        additional_medical_certification_blob_id: additional_blob_id
      }
    end

    # The provider is not a User record; the controller sets I18n.locale via
    # with_request_locale before invoking this service.
    def message(key, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **)
    end

    def validation_message(error)
      case error.error_type
      when :no_attachment
        message(:file_blank)
      when :invalid_type
        message(:file_type_invalid)
      when :file_too_large
        message(:file_too_large, max_size: ProofAttachmentValidator::MAX_FILE_SIZE / 1.megabyte)
      when :file_too_small
        message(:file_too_small)
      when :suspicious_content
        message(:file_suspicious)
      else
        message(:file_invalid)
      end
    end
  end
end
