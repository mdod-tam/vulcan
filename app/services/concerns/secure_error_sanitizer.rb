# frozen_string_literal: true

module SecureErrorSanitizer
  extend ActiveSupport::Concern

  SECURE_URL_PATTERN = %r{https?://[^\s<>"']+}
  TOKEN_ASSIGNMENT_PATTERN = /(\b(?:token|secure_token|public_token|raw_token)=)[^\s&<>"']+/i
  EMAIL_ADDRESS_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
  E164_PHONE_PATTERN = /(?<!\w)\+\d[\d .()-]{7,}\d(?!\w)/
  US_PHONE_PATTERN = /(?<!\w)(?:\(?\d{3}\)?[\s.-]*)\d{3}[\s.-]*\d{4}(?!\w)/
  EMAIL_KEY_PATTERN = /(?:\Aemail\z|_email\z)/i
  SENSITIVE_KEYS = %w[
    public_token
    raw_token
    secure_token
    secure_upload_url
    secure_url
    reset_url
    verification_url
    token
  ].freeze

  def sanitize_secure_error_message(message)
    sanitize_secure_value(message).to_s
  end

  def sanitize_secure_value(value, key = nil)
    return '[REDACTED]' if secure_sensitive_key?(key) || email_sensitive_key?(key)

    case value
    when Hash
      value.to_h do |nested_key, nested_value|
        [nested_key, sanitize_secure_value(nested_value, nested_key)]
      end
    when Array
      value.map { |nested_value| sanitize_secure_value(nested_value) }
    when String
      value
        .gsub(SECURE_URL_PATTERN, '[REDACTED_URL]')
        .gsub(TOKEN_ASSIGNMENT_PATTERN, '\1[REDACTED]')
        .gsub(EMAIL_ADDRESS_PATTERN, '[REDACTED_EMAIL]')
        .gsub(E164_PHONE_PATTERN, '[REDACTED_PHONE]')
        .gsub(US_PHONE_PATTERN, '[REDACTED_PHONE]')
    else
      value
    end
  end

  private

  def secure_sensitive_key?(key)
    SENSITIVE_KEYS.include?(key.to_s)
  end

  def email_sensitive_key?(key)
    key.to_s.match?(EMAIL_KEY_PATTERN)
  end
end
