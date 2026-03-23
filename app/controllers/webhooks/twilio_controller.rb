# frozen_string_literal: true

module Webhooks
  # Controller for handling Twilio webhook callbacks
  class TwilioController < ApplicationController
    FAX_IN_PROGRESS_STATUSES = %w[queued processing sending].freeze
    FAX_FAILURE_STATUSES = %w[failed no-answer busy canceled].freeze
    FAX_TERMINAL_STATUSES = (['delivered'] + FAX_FAILURE_STATUSES).freeze

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
      internal_status = normalize_fax_status(status)

      # Update notification metadata with latest status
      metadata = notification.metadata || {}
      metadata['fax_status'] = internal_status
      metadata['fax_status_updated_at'] = Time.current.iso8601
      metadata['fax_status_details'] = status

      update_attributes = { metadata: metadata }
      delivery_status = normalize_delivery_status(status, notification.delivery_status)
      update_attributes[:delivery_status] = delivery_status if delivery_status.present?
      notification.update!(update_attributes)

      # Handle terminal fax statuses (delivered or failed)
      return unless FAX_TERMINAL_STATUSES.include?(status)

      Rails.logger.info "Fax reached terminal status: #{status} for notification #{notification.id}"

      # Trigger email fallback on fax failure
      trigger_email_fallback(notification, status) if fax_failure_status?(status)
      # Purge blob after terminal status (Twilio has already fetched it)
      purge_fax_blob(notification)
    end

    def normalize_fax_status(status)
      case status
      when *FAX_IN_PROGRESS_STATUSES
        'sending'
      when 'delivered'
        'delivered'
      when 'received'
        'received'
      when *FAX_FAILURE_STATUSES
        'failed'
      else
        'unknown'
      end
    end

    def normalize_delivery_status(status, current_delivery_status)
      return 'delivered' if status == 'delivered'
      return 'error' if fax_failure_status?(status)

      current_delivery_status
    end

    def fax_failure_status?(status)
      FAX_FAILURE_STATUSES.include?(status)
    end

    # Trigger email fallback when fax delivery fails
    def trigger_email_fallback(notification, fax_status)
      Rails.logger.info "Fax delivery failed with status: #{fax_status}, triggering email fallback"

      application = notification.notifiable
      return unless fallback_email_available?(application)

      queue_email_fallback(notification, application, fax_status)

      Rails.logger.info "Email fallback queued for application #{application.id} after fax failure"
    rescue StandardError => e
      handle_email_fallback_error(notification, e)
    end

    def fallback_email_available?(application)
      application.is_a?(Application) && application.medical_provider_email.present?
    end

    def queue_email_fallback(notification, application, fax_status)
      notification.with_lock do
        metadata = notification.metadata || {}
        return if email_fallback_already_sent?(metadata, notification.id)

        mail = build_email_fallback_mail(notification, application, metadata)
        mail.deliver_later
        message_id = mail.message_id

        persist_email_fallback_metadata(notification, metadata, message_id, fax_status)
      end
    end

    def email_fallback_already_sent?(metadata, notification_id)
      return false if metadata['email_fallback_sent_at'].blank?

      Rails.logger.info "Email fallback already queued for notification #{notification_id}; skipping duplicate callback"
      true
    end

    def build_email_fallback_mail(notification, application, metadata)
      rejection_reason = metadata['reason'] ||
                         application.medical_certification_rejection_reason ||
                         'Not specified'
      admin = notification.actor || User.admins.first || User.first

      MedicalProviderMailer.with(
        application: application,
        rejection_reason: rejection_reason,
        admin: admin
      ).certification_rejected
    end

    def persist_email_fallback_metadata(notification, metadata, message_id, fax_status)
      metadata['email_fallback_sent_at'] = Time.current.iso8601
      metadata['email_fallback_message_id'] = message_id
      metadata['email_fallback_status'] = 'queued'
      metadata['email_fallback_trigger_status'] = fax_status
      metadata['message_id'] = message_id if message_id.present?

      notification.update!(metadata: metadata)
    end

    def handle_email_fallback_error(notification, error)
      Rails.logger.error "Failed to trigger email fallback: #{error.message}"

      metadata = notification.metadata || {}
      metadata['email_fallback_error'] = error.message
      metadata['email_fallback_error_at'] = Time.current.iso8601
      notification.update!(metadata: metadata)
    rescue StandardError
      # Best effort metadata enrichment only
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
