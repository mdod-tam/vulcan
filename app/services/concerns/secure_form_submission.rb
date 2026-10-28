# frozen_string_literal: true

# Shared result contract for public secure form submissions. The public page
# receives translated messages; logs identify failures by class and form ID.
# A service defines request_form (its secure form record) and message(key, **).
module SecureFormSubmission
  extend ActiveSupport::Concern
  include SecureErrorSanitizer

  class AttachmentFailure < StandardError; end

  included do
    attr_reader :form_errors

    delegate :model_name, to: :class
  end

  class_methods do
    def human_attribute_name(attribute, *_args)
      attribute.to_s.humanize
    end

    def lookup_ancestors
      [self]
    end
  end

  def read_attribute_for_validation(attribute)
    public_send(attribute)
  end

  private

  # Match issuance's owner-before-form lock order and recheck after both locks.
  def submit_under_lock(owner)
    ApplicationRecord.transaction do
      owner.lock!
      request_form.lock!
      next inactive_request_failure unless request_form.active_for_public_use?

      yield
    end
  rescue UploadedDocument::Refused => e
    refused_upload_failure(e)
  rescue AttachmentFailure => e
    failure(e.message)
  rescue ActiveRecord::RecordInvalid => e
    failure(e.record.errors.full_messages.to_sentence, { errors: e.record.errors })
  end

  # The document write, consumption, and audit share the caller's transaction.
  def complete_submission
    request_form.mark_submitted!
    yield
    success(message(:submitted))
  end

  def invalid_request_failure
    failure(message(:invalid_request))
  end

  def inactive_request_failure
    key = if request_form.submitted?
            :already_submitted
          elsif request_form.revoked?
            :revoked
          elsif request_form.expired?
            :expired
          else
            :invalid_request
          end

    failure(message(key))
  end

  def validation_failure
    failure(message(:validation_failed), { errors: form_errors })
  end

  # UploadedDocument refused the file inside the submission transaction, which rolled back,
  # so the request stays active and the page shows why.
  def refused_upload_failure(refusal)
    @form_errors = ActiveModel::Errors.new(self)
    form_errors.add(:file, refusal.reason, message: refusal.user_message)
    validation_failure
  end

  # Raises with a translated message and logs the failure class.
  def raise_attachment_failure(error)
    Rails.logger.warn("#{self.class.name} attachment failed for form #{request_form.id}: " \
                      "#{error&.class&.name}")
    raise AttachmentFailure, message(:attachment_failed)
  end
end
