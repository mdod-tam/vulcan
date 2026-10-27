# frozen_string_literal: true

require 'webhook_signature'

module Webhooks
  # Base controller for webhook tests. It skips authentication and replaces signature verification
  # with a presence check.
  class TestBaseController < BaseController
    skip_before_action :sign_in, raise: false

    def verify_webhook_signature
      signature = request.headers['X-Webhook-Signature']

      webhook_debug("Verifying signature: #{signature}")

      if signature.nil? || signature == 'invalid'
        webhook_debug("Signature verification failed: #{signature.nil? ? 'missing' : 'invalid'}")
        head :unauthorized
        return false
      end

      # The signature is not checked against the payload. It only has to be present and not "invalid".
      webhook_debug('Signature verification passed')
      true
    end

    private

    def webhook_debug(message)
      return unless ENV['DEBUG_WEBHOOKS'] == 'true'

      Rails.logger.debug { "[WEBHOOK DEBUG] #{message}" }
    end
  end
end
