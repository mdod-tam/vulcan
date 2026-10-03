# frozen_string_literal: true

# Shared result contract for public secure form submissions. The public page
# only ever receives translated messages; raw errors go to the log.
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

  # Raises with a translated message. The raw error, which can name storage
  # keys or database details, is logged and never shown to the public.
  def raise_attachment_failure(error)
    Rails.logger.warn("#{self.class.name} attachment failed for form #{request_form.id}: " \
                      "#{sanitize_secure_error_message(error&.message.to_s)}")
    raise AttachmentFailure, message(:attachment_failed)
  end
end
