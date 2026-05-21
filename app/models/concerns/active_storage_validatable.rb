# frozen_string_literal: true

# Centralized ActiveStorage validation concern
# Provides standardized constants and validation methods for file uploads
# across the entire application to eliminate inconsistencies.
module ActiveStorageValidatable
  extend ActiveSupport::Concern

  ALLOWED_CONTENT_TYPES = ProofUploadFormats::ALLOWED_CONTENT_TYPES

  # Standard file size limits (5MB is the most commonly used)
  MAX_FILE_SIZE = 5.megabytes
  MIN_FILE_SIZE = Rails.env.test? ? 1.byte : 1.kilobyte

  # JavaScript-friendly constants for client-side validation
  JS_VALIDATION_CONFIG = {
    allowed_types: ALLOWED_CONTENT_TYPES,
    max_size_bytes: MAX_FILE_SIZE,
    max_size_mb: MAX_FILE_SIZE / 1.megabyte,
    error_messages: {
      invalid_type: ProofUploadFormats::INVALID_TYPE_MESSAGE,
      file_too_large: "File is too large. Maximum size allowed is #{MAX_FILE_SIZE / 1.megabyte}MB.",
      file_too_small: "File is too small. Minimum size required is #{MIN_FILE_SIZE} bytes.",
      no_file: 'Please select a file to upload.'
    }
  }.freeze

  included do
    private

    def validate_attachment_content_type(attachment, attribute)
      return unless attachment.attached?

      return if ALLOWED_CONTENT_TYPES.include?(attachment.content_type)

      errors.add(attribute, JS_VALIDATION_CONFIG[:error_messages][:invalid_type])
    end

    def validate_attachment_size(attachment, attribute)
      return unless attachment.attached?

      if attachment.byte_size < MIN_FILE_SIZE
        errors.add(attribute, JS_VALIDATION_CONFIG[:error_messages][:file_too_small])
      elsif attachment.byte_size > MAX_FILE_SIZE
        errors.add(attribute, JS_VALIDATION_CONFIG[:error_messages][:file_too_large])
      end
    end

    def validate_attachment(attachment, attribute)
      validate_attachment_content_type(attachment, attribute)
      validate_attachment_size(attachment, attribute)
    end
  end

  class_methods do
    def validate_file_params(file)
      errors = []

      return [JS_VALIDATION_CONFIG[:error_messages][:no_file]] if file.blank?

      errors << JS_VALIDATION_CONFIG[:error_messages][:invalid_type] unless ALLOWED_CONTENT_TYPES.include?(file.content_type)

      if file.size < MIN_FILE_SIZE
        errors << JS_VALIDATION_CONFIG[:error_messages][:file_too_small]
      elsif file.size > MAX_FILE_SIZE
        errors << JS_VALIDATION_CONFIG[:error_messages][:file_too_large]
      end

      errors
    end

    def js_validation_config
      JS_VALIDATION_CONFIG
    end
  end
end
