# frozen_string_literal: true

module Vendors
  class RequestW9Resubmission < BaseService
    include SecureFormLocaleResolver

    MESSAGE_SCOPE = 'vendors.w9_resubmission.messages'

    attr_reader :vendor, :actor, :resend_of, :public_recovery

    def initialize(vendor:, actor:, resend_of: nil, public_recovery: false)
      super()
      @vendor = vendor
      @actor = actor
      @resend_of = resend_of
      @public_recovery = public_recovery
    end

    def call
      return failure(message(:recipient_email_required)) if recipient_email.blank?
      return failure(message(:request_not_needed)) unless requestable_w9_state?
      return failure(message(:missing_rejection_review)) if vendor.w9_status_rejected? && latest_rejection_review.blank?

      request_form = nil
      raw_token = nil

      ApplicationRecord.transaction do
        vendor.with_lock do
          ensure_cooldown_allows!
          revoke_open_requests
          request_form, raw_token = create_request
        end
      end

      deliver_request_email!(raw_token)

      success(message(:request_created), result_data(request_form, raw_token))
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("W9 resubmission request failed for vendor #{vendor.id}: #{e.message}")
      failure(message(:request_conflict))
    rescue CooldownActive => e
      return success(message(:resent)) if public_recovery

      failure(e.message)
    rescue StandardError => e
      Rails.logger.warn("W9 resubmission delivery failed for vendor #{vendor.id}: #{sanitize_secure_error_message(e.message)}")
      request_form&.persisted? ? delivery_failure(request_form, e) : failure(message(:delivery_failed))
    end

    private

    def ensure_cooldown_allows!
      latest_request = VendorSecureRequestForm
                       .w9_upload
                       .where(vendor: vendor)
                       .where.not(status: :revoked)
                       .order(sent_at: :desc)
                       .first
      return if latest_request.blank?

      cooldown_until = latest_request.sent_at + resend_cooldown_hours.hours
      return if cooldown_until <= Time.current

      minutes = ((cooldown_until - Time.current) / 60.0).ceil
      raise CooldownActive, message(:cooldown_active, minutes: minutes)
    end

    def revoke_open_requests
      VendorSecureRequestForm
        .open_w9_upload_for_vendor(vendor_id: vendor.id)
        .find_each { |request_form| request_form.revoke!(actor: actor, reason: :replacement_request) }
    end

    def create_request
      request_form = nil
      raw_token = nil
      attempts = 0

      begin
        attempts += 1
        raw_token = VendorSecureRequestForm.generate_public_token
        request_form = VendorSecureRequestForm.create!(request_form_attributes(raw_token))
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < 2

        raise
      end

      create_tracking_notification(request_form)
      [request_form, raw_token]
    end

    def request_form_attributes(raw_token)
      {
        vendor: vendor,
        kind: :w9_upload,
        status: :sent,
        recipient_email: recipient_email,
        public_token_digest: VendorSecureRequestForm.digest_public_token(raw_token),
        expires_at: link_expiration_hours.hours.from_now,
        sent_at: Time.current,
        request_batch_id: SecureRandom.uuid,
        requested_by: actor
      }
    end

    def create_tracking_notification(request_form)
      NotificationService.create_and_deliver!(
        type: 'w9_resubmission_requested',
        recipient: vendor,
        actor: actor,
        notifiable: vendor,
        metadata: {
          vendor_secure_request_form_id: request_form.id,
          vendor_id: vendor.id,
          request_batch_id: request_form.request_batch_id,
          expires_at: request_form.expires_at.iso8601
        },
        channel: :email,
        audit: true,
        deliver: false
      )
    end

    def delivery_failure(request_form, error)
      persist_delivery_failure(request_form, error)
      revoke_failed_request(request_form, error)
      failure(message(:delivery_failed), delivery_failure_data(request_form, error))
    end

    def revoke_failed_request(request_form, error)
      return unless request_form&.active?

      request_form.revoke!(
        actor: actor,
        reason: :delivery_failure,
        metadata: { delivery_failure: delivery_failure_context(request_form, error) }
      )
    rescue StandardError => e
      Rails.logger.error(
        "W9 resubmission delivery failure revocation failed: #{sanitize_secure_error_message(e.message)}"
      )
    end

    def persist_delivery_failure(request_form, error)
      notification = tracking_notification_for(request_form)
      return if notification.blank?

      notification.update!(
        delivery_status: :error,
        metadata: (notification.metadata || {}).merge(
          delivery_error: delivery_failure_context(request_form, error)
        )
      )
    end

    def tracking_notification_for(request_form)
      Notification
        .where(notifiable: vendor, action: 'w9_resubmission_requested')
        .where("metadata->>'vendor_secure_request_form_id' = ?", request_form.id.to_s)
        .order(created_at: :desc)
        .first
    end

    def delivery_failure_data(request_form, error)
      {
        vendor_secure_request_form: request_form,
        delivery_error: true,
        delivery_failure: delivery_failure_context(request_form, error)
      }
    end

    def delivery_failure_context(request_form, error)
      {
        error_class: error.class.name,
        error_message: sanitize_secure_error_message(error.message),
        vendor_secure_request_form_id: request_form.id,
        vendor_id: vendor.id,
        request_batch_id: request_form.request_batch_id,
        recipient_email: request_form.recipient_email,
        template_name: delivery_template_name
      }
    end

    def deliver_request_email!(raw_token)
      secure_upload_url = secure_upload_url_for(raw_token)

      # Keep the bearer URL out of job payload serialization.
      mailer = VendorNotificationsMailer.with(
        vendor: vendor,
        w9_review: latest_rejection_review,
        secure_upload_url: secure_upload_url
      )
      if latest_rejection_review.present?
        mailer.w9_rejected.deliver_now
      else
        mailer.w9_upload_requested.deliver_now
      end
    end

    def secure_upload_url_for(raw_token)
      options = Rails.application.config.action_mailer.default_url_options || {}
      host = options[:host]
      protocol = options[:protocol] || (Rails.env.production? ? 'https' : 'http')

      if Rails.env.production?
        raise ArgumentError, 'Secure W9 form host is not configured' if host.blank? || host == 'example.com'
        raise ArgumentError, 'Secure W9 form URLs must use HTTPS in production' unless protocol == 'https'
      end

      Rails.application.routes.url_helpers.secure_w9_form_url(
        token: raw_token,
        host: host,
        port: options[:port],
        protocol: protocol
      )
    end

    def result_data(request_form, raw_token)
      {
        vendor_secure_request_form: request_form,
        secure_upload_url: secure_upload_url_for(raw_token)
      }
    end

    def latest_rejection_review
      @latest_rejection_review ||= vendor.w9_reviews.where(status: :rejected).order(reviewed_at: :desc, created_at: :desc).first
    end

    def requestable_w9_state?
      vendor.w9_status_not_submitted? || vendor.w9_status_rejected?
    end

    def delivery_template_name
      latest_rejection_review.present? ? 'vendor_notifications_w9_rejected' : 'vendor_notifications_w9_upload_requested'
    end

    def recipient_email
      resend_of&.recipient_email.presence || vendor.email
    end

    def link_expiration_hours
      Policy.get('secure_form_link_expiration_hours') || 48
    end

    def resend_cooldown_hours
      Policy.get('secure_form_resend_cooldown_hours') || 1
    end

    def message(key, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(vendor))
    end

    class CooldownActive < StandardError; end
  end
end
