# frozen_string_literal: true

module Applications
  class SubmitProofResubmission < BaseService
    include SecureFormLocaleResolver

    MESSAGE_SCOPE = 'applications.proof_resubmission.messages'
    KIND_TO_PROOF_TYPE = {
      'id_proof_resubmission' => :id,
      'residency_proof_resubmission' => :residency,
      'income_proof_resubmission' => :income
    }.freeze
    class AttachmentFailure < StandardError; end

    attr_reader :application, :secure_request_form, :file, :form_errors

    delegate :model_name, to: :class

    def self.human_attribute_name(attribute, *_args)
      attribute.to_s.humanize
    end

    def self.lookup_ancestors
      [self]
    end

    def self.model_name
      ActiveModel::Name.new(self, nil, 'ProofResubmission')
    end

    def initialize(application:, secure_request_form:, file:)
      super()
      @application = application
      @secure_request_form = secure_request_form
      @file = file
    end

    def call
      return invalid_request_failure unless secure_request_form.application_id == application.id
      return inactive_request_failure unless secure_request_form.active_for_public_use?
      return invalid_request_failure unless proof_type
      return validation_failure unless file_valid?

      result = nil

      ApplicationRecord.transaction do
        secure_request_form.with_lock do
          secure_request_form.reload
          unless secure_request_form.active_for_public_use?
            result = inactive_request_failure
            next
          end

          attach_result = attach_proof
          raise AttachmentFailure, attach_result[:error]&.message || message(:attachment_failed) unless attach_result[:success]

          secure_request_form.mark_submitted!
          log_submission
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

    def invalid_request_failure
      failure(message(:invalid_request))
    end

    def inactive_request_failure
      key = if secure_request_form.submitted?
              :already_submitted
            elsif secure_request_form.revoked?
              :revoked
            elsif secure_request_form.expired?
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

    def proof_type
      KIND_TO_PROOF_TYPE[secure_request_form.kind]
    end

    def attach_proof
      ProofAttachmentService.attach_proof(
        application: application,
        proof_type: proof_type,
        blob_or_file: file,
        submission_method: :secure_form,
        status: :not_reviewed,
        metadata: {
          secure_request_form_id: secure_request_form.id,
          request_batch_id: secure_request_form.request_batch_id
        }
      )
    end

    def log_submission
      AuditEventService.log(
        action: 'proof_submitted_via_secure_form',
        actor: secure_request_form.recipient,
        auditable: application,
        metadata: {
          secure_request_form_id: secure_request_form.id,
          recipient_user_id: secure_request_form.recipient_id,
          recipient_role: secure_request_form.recipient_role,
          request_batch_id: secure_request_form.request_batch_id,
          proof_type: proof_type.to_s
        }
      )
    end

    def message(key, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(secure_request_form.recipient))
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
