# frozen_string_literal: true

module Webhooks
  class InvalidPayloadError < StandardError; end

  class BaseController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :verify_webhook_signature
    before_action :validate_payload
    around_action :log_webhook

    rescue_from InvalidPayloadError, with: :handle_invalid_payload

    private

    def validate_payload
      raise InvalidPayloadError unless valid_payload?
    end

    def valid_payload?
      raise NotImplementedError, 'Subclasses must implement #valid_payload?'
    end

    def handle_invalid_payload
      head :unprocessable_content
    end

    def verify_webhook_signature
      signature = request.headers['X-Webhook-Signature']

      # Return unauthorized if signature is missing
      if signature.nil?
        head :unauthorized
        return false
      end

      data = request.raw_post
      expected = compute_signature(data)

      unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)
        head :unauthorized
        return false
      end

      true
    end

    def compute_signature(payload)
      secret = Rails.application.credentials.webhook_secret || 'test_webhook_secret'
      OpenSSL::HMAC.hexdigest(
        'sha256',
        secret,
        payload
      )
    end

    def log_webhook(&)
      ActiveSupport::Notifications.instrument(
        'webhook_received',
        controller: self.class.name,
        action: action_name,
        type: params[:type], &
      )
    end
  end
end
