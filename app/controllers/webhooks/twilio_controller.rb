# frozen_string_literal: true

module Webhooks
  # Twilio status callbacks.
  class TwilioController < ApplicationController
    skip_before_action :authenticate_user!
    skip_before_action :verify_authenticity_token
    before_action :verify_twilio_signature, only: [:fax_status]

    # POST fax delivery status for a fax sent to a medical provider.
    def fax_status
      fax_sid = params[:FaxSid]
      status = params[:Status]

      Rails.logger.info "Received fax status update for SID: #{fax_sid}, Status: #{status}"

      # The notification metadata holds the fax_sid of the fax it sent.
      notification = Notification.find_by("metadata->>'fax_sid' = ?", fax_sid)

      if notification.present?
        MedicalProviderNotifier.new(notification.notifiable).receive_fax_status(notification, fax_sid: fax_sid, status: status)
        render json: { success: true, status: status }, status: :ok
      else
        # An unknown SID is logged and still answered with 200.
        Rails.logger.warn "Could not find notification for fax SID: #{fax_sid}"
        render json: { success: false, error: 'Notification not found' }, status: :ok
      end
    rescue StandardError => e
      Rails.logger.error "Error handling fax status update: #{e.class.name}"
      render json: { success: false, error: 'Callback could not be processed' }, status: :internal_server_error
    end

    private

    def verify_twilio_signature
      # The X-Twilio-Signature header is checked against the auth token in production only.
      return true unless Rails.env.production?

      validator = Twilio::Security::RequestValidator.new(Rails.application.config.twilio[:auth_token])
      signature = request.headers['X-Twilio-Signature']
      url = request.original_url

      unless validator.validate(url, params.to_unsafe_h, signature)
        Rails.logger.warn 'Invalid Twilio signature for fax status callback'
        render json: { error: 'Invalid signature' }, status: :forbidden
        return false
      end

      true
    end
  end
end
