# frozen_string_literal: true

module Applications
  class SubmitProofResubmission < BaseService
    include SecureFormSubmission

    MESSAGE_SCOPE = 'applications.proof_resubmission.messages'
    KIND_TO_PROOF_TYPE = SecureRequestForm::PROOF_TYPES_BY_KIND.transform_values(&:to_sym).freeze

    attr_reader :application, :secure_request_form, :file

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
        # Lock the application before the form, in the same order as issuance.
        application.lock!
        secure_request_form.lock!
        unless secure_request_form.active_for_public_use?
          result = inactive_request_failure
          next
        end

        # Another path can approve or replace the proof after the link was sent.
        unless application.proof_requestable_via_secure_form?(proof_type)
          log_refused_submission
          result = failure(message(:no_longer_needed))
          next
        end

        attach_result = attach_proof
        raise_attachment_failure(attach_result[:error]) unless attach_result[:success]

        secure_request_form.mark_submitted!
        log_submission
        result = success(message(:submitted))
      end

      result
    rescue AttachmentFailure => e
      failure(e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { errors: e.record.errors })
    end

    private

    def request_form = secure_request_form

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
      PublicAuditActor.log_audit(
        action: 'proof_submitted_via_secure_form',
        auditable: application,
        metadata: {
          secure_request_form_id: secure_request_form.id,
          recipient_user_id: secure_request_form.recipient_id,
          recipient_role: secure_request_form.recipient_role,
          delivery_owner_id: secure_request_form.delivery_owner_id,
          delivery_source: secure_request_form.delivery_source,
          recipient_channel: secure_request_form.recipient_channel,
          request_batch_id: secure_request_form.request_batch_id,
          proof_type: proof_type.to_s
        }
      )
    end

    def log_refused_submission
      PublicAuditActor.log_audit(
        action: 'proof_secure_submission_refused',
        auditable: application,
        metadata: {
          secure_request_form_id: secure_request_form.id,
          request_batch_id: secure_request_form.request_batch_id,
          proof_type: proof_type.to_s,
          proof_status: application.public_send("#{proof_type}_proof_status"),
          reason: 'proof_no_longer_requestable'
        }
      )
    end

    def message(key, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_request_form.delivery_locale)
    end
  end
end
