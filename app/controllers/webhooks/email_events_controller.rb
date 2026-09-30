# frozen_string_literal: true

module Webhooks
  # Postmark supports HTTP Basic authentication, not the sibling providers' HMAC scheme.
  class EmailEventsController < BaseController
    skip_before_action :verify_webhook_signature
    prepend_before_action :authenticate_postmark

    def create
      EmailDelivery::Feedback.apply(@feedback, server_id: @postmark_server_id)
      head :ok
    rescue EmailDelivery::Feedback::Invalid
      head :unprocessable_content
    end

    private

    def authenticate_postmark
      @postmark_server_id = EmailDelivery.postmark_server_id!
      username = ENV['POSTMARK_WEBHOOK_USERNAME'].to_s
      password = ENV['POSTMARK_WEBHOOK_PASSWORD'].to_s
      configured = username.present? && password.present?
      authorized = configured && authenticate_with_http_basic do |given_username, given_password|
        ActiveSupport::SecurityUtils.secure_compare(given_username, username) &
          ActiveSupport::SecurityUtils.secure_compare(given_password, password)
      end
      head :unauthorized unless authorized
    rescue EmailDelivery::ConfigurationError
      head :unauthorized
    end

    def valid_payload?
      return false unless params[:ServerID].to_s == @postmark_server_id

      @feedback = EmailDelivery::Feedback.webhook(params.to_unsafe_h)
      true
    rescue EmailDelivery::Feedback::Invalid, TypeError, NoMethodError
      false
    end
  end
end
