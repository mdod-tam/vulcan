# frozen_string_literal: true

module SecureErrorSanitizer
  extend ActiveSupport::Concern

  SECURE_URL_PATTERN = %r{https?://[^\s<>"']+}
  TOKEN_ASSIGNMENT_PATTERN = /(\b(?:token|secure_token|public_token|raw_token)=)[^\s&<>"']+/i
  SENSITIVE_KEYS = %w[
    public_token
    raw_token
    secure_token
    secure_upload_url
    secure_url
    token
  ].freeze

  def sanitize_secure_error_message(message)
    sanitize_secure_value(message).to_s
  end

  def sanitize_secure_value(value, key = nil)
    return '[REDACTED]' if secure_sensitive_key?(key)

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
    else
      value
    end
  end

  private

  def secure_sensitive_key?(key)
    SENSITIVE_KEYS.include?(key.to_s)
  end
end
