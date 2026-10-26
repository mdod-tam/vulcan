# frozen_string_literal: true

# HMAC-SHA256 signature for webhook payloads.
module WebhookSignature
  # @param payload [String] The raw payload to sign
  # @param secret [String, nil] The signing secret (defaults to the webhook_secret credential)
  # @return [String] The hex-encoded HMAC-SHA256 signature
  def self.compute_signature(payload, secret = nil)
    secret ||= Rails.application.credentials.webhook_secret

    OpenSSL::HMAC.hexdigest('sha256', secret, payload)
  end
end
