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
        update_notification_status(notification, status)
        render json: { success: true, status: status }, status: :ok
      else
        # Log but don't fail if we can't find the notification
        Rails.logger.warn "Could not find notification for fax SID: #{fax_sid}"
        render json: { success: false, error: 'Notification not found' }, status: :ok
      end
    rescue StandardError => e
      Rails.logger.error "Error handling fax status update: #{e.message}"
      render json: { success: false, error: e.message }, status: :internal_server_error
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

    def update_notification_status(notification, status)
      # Map Twilio fax status to our internal status
      internal_status = case status
                        when 'queued', 'processing', 'sending'
                          'sending'
                        when 'delivered'
                          'delivered'
                        when 'received'
                          'received'
                        when 'no-answer', 'busy', 'failed', 'canceled'
                          'failed'
                        else
                          'unknown'
                        end

      # Update notification metadata with latest status
      metadata = notification.metadata || {}
      metadata['fax_status'] = internal_status
      metadata['fax_status_updated_at'] = Time.current.iso8601
      metadata['fax_status_details'] = status

      notification.update!(
        metadata: metadata,
        delivery_status: internal_status == 'delivered' ? 'delivered' : 'failed'
      )

      # Handle terminal fax statuses (delivered or failed)
      return unless %w[delivered failed no-answer busy canceled].include?(status)

      Rails.logger.info "Fax reached terminal status: #{status} for notification #{notification.id}"

      # Trigger email fallback on fax failure
      trigger_email_fallback(notification, status) if %w[failed no-answer busy canceled].include?(status)
      # Purge blob after terminal status (Twilio has already fetched it)
      purge_fax_blob(notification)
    end

    # Trigger email fallback when fax delivery fails
    def trigger_email_fallback(notification, fax_status)
      Rails.logger.info "Fax delivery failed with status: #{fax_status}, triggering email fallback"
      application = notification.notifiable
      return unless application.is_a?(Application)
      return if application.medical_provider_email.blank?

      # Extract rejection reason from notification metadata
      rejection_reason = notification.metadata['reason'] ||
                         application.medical_certification_rejection_reason ||
                         'Not specified'
      admin = notification.actor

      # Send email as fallback
      MedicalProviderMailer.with(
        application: application,
        rejection_reason: rejection_reason,
        admin: admin
      ).certification_rejected.deliver_later

      Rails.logger.info "Email fallback queued for application #{application.id} after fax failure"
    rescue StandardError => e
      Rails.logger.error "Failed to trigger email fallback: #{e.message}"
      # Don't fail the webhook - email fallback is best effort
    end

    # Purge the fax blob after terminal status
    def purge_fax_blob(notification)
      blob_id = notification.metadata['blob_id']
      return if blob_id.blank?

      blob = ActiveStorage::Blob.find_by(id: blob_id)
      if blob
        Rails.logger.info "Purging fax blob #{blob_id} after terminal status for notification #{notification.id}"
        blob.purge_later
      else
        Rails.logger.warn "Blob #{blob_id} not found for purging (may have already been deleted)"
      end
    rescue StandardError => e
      Rails.logger.error "Failed to purge fax blob #{blob_id}: #{e.message}"
      # Don't fail webhook - blob cleanup is best effort
    end
  end
end
