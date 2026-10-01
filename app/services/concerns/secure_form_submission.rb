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

  # max_file_size is the purpose's inclusive limit; the validator's default applies until a purpose sets one
  def file_valid?(max_file_size: ProofAttachmentValidator::MAX_FILE_SIZE)
    @form_errors = ActiveModel::Errors.new(self)
    ProofAttachmentValidator.validate!(file, max_file_size: max_file_size)
    true
  rescue ProofAttachmentValidator::ValidationError => e
    form_errors.add(:file, e.error_type, message: file_validation_message(e, max_file_size))
    false
  end

  def file_validation_message(error, max_file_size)
    case error.error_type
    when :no_attachment then message(:file_blank)
    when :invalid_type then message(:file_type_invalid)
    when :file_too_large then message(:file_too_large, max_size: max_file_size / 1.megabyte)
    when :file_too_small then message(:file_too_small)
    when :suspicious_content then message(:file_suspicious)
    else message(:file_invalid)
    end
  end

  # Raises with a translated message. The raw error, which can name storage
  # keys or database details, is logged and never shown to the public.
  def raise_attachment_failure(error)
    Rails.logger.warn("#{self.class.name} attachment failed for form #{request_form.id}: " \
                      "#{sanitize_secure_error_message(error&.message.to_s)}")
    raise AttachmentFailure, message(:attachment_failed)
  end
end
