# frozen_string_literal: true

# Enhanced debugging for Postmark client formatting differences.
# Payload logging is opt-in and redacted because Postmark bodies can contain
# password reset and verification links.

module PostmarkDebugger
  BODY_KEYS = %w[Body HtmlBody TextBody Attachments].freeze
  SENSITIVE_VALUE_KEYS = %w[
    email_verification_url raw_token reset_url secure_token secure_url token verification_url
  ].freeze
  TOKEN_ASSIGNMENT_PATTERN = /(\b[\w-]*token=)[^&\s"'<>]+/i
  URL_PATTERN = %r{https?://[^\s"'<>]+}i

  def post(path, data = {})
    log_postmark_payload('ORIGINAL', data)

    normalize_postmark_email_payload(data) if path == '/email' && data.is_a?(Hash)

    log_postmark_payload('MODIFIED', data)

    # Call the original method
    super
  end

  # Simple error logging without trying to inspect the response type
  def handle_response(response)
    result = super
    Rails.logger.info 'POSTMARK SUCCESS: Email sent successfully'
    result
  rescue StandardError => e
    Rails.logger.error { "POSTMARK ERROR: #{e.class} - #{redacted_postmark_log_message(e.message)}" }
    raise
  end

  private

  def normalize_postmark_email_payload(data)
    # Ensure MessageStream is a top-level parameter, not a header
    if data['Headers']&.any? { |h| h['Name'] == 'X-PM-Message-Stream' }
      stream_header = data['Headers'].find { |h| h['Name'] == 'X-PM-Message-Stream' }
      data['MessageStream'] = stream_header['Value'] if stream_header
      data['Headers'].delete_if { |h| h['Name'] == 'X-PM-Message-Stream' }
    end

    # Always remove ReplyTo field to match our successful curl request
    data.delete('ReplyTo')

    # Simplify Headers to match our curl request
    return unless data['Headers']&.any?

    # Keep only essential headers
    data['Headers'].select! do |header|
      %w[Message-ID Content-Type].include?(header['Name'])
    end

    # Remove Headers entirely if empty
    data.delete('Headers') if data['Headers'].empty?
  end

  def log_postmark_payload(label, payload)
    return unless ENV.fetch('POSTMARK_DEBUG_PAYLOADS', '').casecmp('true').zero?

    Rails.logger.debug { "POSTMARK PAYLOAD (#{label}): #{redacted_postmark_payload(payload).to_json}" }
  end

  def redacted_postmark_log_message(message)
    redacted_postmark_payload(message.to_s)
  end

  def redacted_postmark_payload(value, key = nil)
    return '[REDACTED_BODY]' if BODY_KEYS.include?(key.to_s)
    return '[REDACTED]' if SENSITIVE_VALUE_KEYS.include?(key.to_s)

    case value
    when Hash
      value.each_with_object({}) do |(nested_key, nested_value), redacted_payload|
        redacted_payload[nested_key] = redacted_postmark_payload(nested_value, nested_key)
      end
    when Array
      value.map { |nested_value| redacted_postmark_payload(nested_value) }
    when String
      value.gsub(URL_PATTERN, '[REDACTED_URL]')
           .gsub(TOKEN_ASSIGNMENT_PATTERN, '\1[REDACTED]')
    else
      value
    end
  end
end

Postmark::HttpClient.prepend(PostmarkDebugger) if defined?(Postmark::HttpClient)
