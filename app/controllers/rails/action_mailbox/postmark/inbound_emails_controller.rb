# frozen_string_literal: true

module Rails
  module ActionMailbox
    module Postmark
      class InboundEmailsController < ApplicationController
        skip_before_action :verify_authenticity_token
        skip_before_action :authenticate_user!
        before_action :ensure_authentic

        def create
          ::ActionMailbox::InboundEmail.create_and_extract_message_id!(inbound_email_params)
          head :ok
        rescue StandardError => e
          Rails.logger.error("Error processing Postmark inbound email: #{e.message}")
          head :unprocessable_content
        end

        private

        def inbound_email_params
          # Postmark sends the raw email content in the RawEmail param
          # This is what Action Mailbox needs to process the email
          params.require(:RawEmail)
        end

        def ensure_authentic
          if authenticator.authentic_request?(request)
            true # Authentication succeeded, continue with the filter chain
          else
            head :unauthorized
            false # Authentication failed, halt the filter chain
          end
        end

        def authenticator
          @authenticator ||= if ActionMailbox.ingress_password.present?
                               PasswordAuthenticator.new(ActionMailbox.ingress_password)
                             else
                               WebhookAuthenticator.new
                             end
        end

        # Different authenticator strategies

        class PasswordAuthenticator
          def initialize(password)
            @password = password
          end

          def authentic_request?(request)
            return false if request.headers['X-Postmark-Signature'].blank?

            # Check if the signature matches the expected value
            expected_signature = OpenSSL::HMAC.hexdigest(
              'sha256',
              @password,
              request.raw_post
            )

            ActiveSupport::SecurityUtils.secure_compare(
              request.headers['X-Postmark-Signature'],
              expected_signature
            )
          end
        end

        class WebhookAuthenticator
          def authentic_request?(request)
            # In production, we'd use the Postmark webhook token from the app's credentials
            webhook_token = Rails.application.credentials.dig(:postmark, :webhook_token) ||
                            ENV.fetch('POSTMARK_WEBHOOK_TOKEN', nil)

            return false if webhook_token.blank?
            return false if request.headers['X-Postmark-Signature'].blank?

            # Calculate the expected signature using the webhook token
            expected_signature = OpenSSL::HMAC.hexdigest(
              'sha256',
              webhook_token,
              request.raw_post
            )

            # Compare the signatures securely
            ActiveSupport::SecurityUtils.secure_compare(
              request.headers['X-Postmark-Signature'],
              expected_signature
            )
          end
        end
      end
    end
  end
end
