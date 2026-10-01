# frozen_string_literal: true

module Webhooks
  # Controller for handling Twilio webhook callbacks
  class TwilioController < ApplicationController
    skip_before_action :authenticate_user!
    skip_before_action :verify_authenticity_token
    before_action :verify_twilio_signature, only: [:fax_status]

    # Handle fax status updates from Twilio
    def fax_status
      fax_sid = params[:FaxSid]
      status = params[:Status]

      Rails.logger.info "Received fax status update for SID: #{fax_sid}, Status: #{status}"

      # Find the associated notification or event record
      # This assumes you're storing the fax_sid in metadata when sending the fax
      notification = Notification.find_by("metadata->>'fax_sid' = ?", fax_sid)

      if notification.present?
        MedicalProviderNotifier.new(notification.notifiable).receive_fax_status(notification, fax_sid: fax_sid, status: status)
        render json: { success: true, status: status }, status: :ok
      else
        # Log but don't fail if we can't find the notification
        Rails.logger.warn "Could not find notification for fax SID: #{fax_sid}"
        render json: { success: false, error: 'Notification not found' }, status: :ok
      end
    rescue StandardError => e
      Rails.logger.error "Error handling fax status update: #{e.message}"
      render json: { success: false, error: 'Callback could not be processed' }, status: :internal_server_error
    end

    private

    def verify_twilio_signature
      # Production implementations should verify the request is coming from Twilio
      # by checking the X-Twilio-Signature header against your auth token
      return true unless Rails.env.production?

      # Verify Twilio signature to prevent unauthorized webhook calls
      validator = Twilio::Security::RequestValidator.new(Rails.application.config.twilio[:auth_token])
      signature = request.headers['X-Twilio-Signature']
      url = request.original_url

      unless validator.validate(url, params.to_unsafe_h, signature)
        Rails.logger.warn "Invalid Twilio signature for request to #{url}"
        render json: { error: 'Invalid signature' }, status: :forbidden
        return false
      end

      true
    end
  end
end
