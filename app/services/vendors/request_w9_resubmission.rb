# frozen_string_literal: true

module Vendors
  class RequestW9Resubmission < BaseService
    include SecureFormLocaleResolver
    include Applications::SecureRequestDeliveryPolicy

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

      denial = authorize_delivery
      return denial if denial

      delivery = nil

      ApplicationRecord.transaction do
        vendor.with_lock do
          ensure_cooldown_allows!
          revoke_open_requests
          delivery = create_request
        end
      end

      result = deliver_requests([delivery])
      return result if result.failure?

      success(message(:request_created), result_data(delivery.secure_request_form, delivery.raw_token))
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("W9 resubmission request failed for vendor #{vendor.id}: #{e.message}")
      failure(message(:request_conflict))
    rescue CooldownActive => e
      return success(message(:resent)) if public_recovery

      failure(e.message)
    rescue StandardError => e
      Rails.logger.warn("W9 resubmission request failed for vendor #{vendor.id}: #{sanitize_secure_error_message(e.message)}")
      failure(message(:delivery_failed))
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

      cooldown_until = latest_request.sent_at + SecureFormPolicy.resend_cooldown_hours.hours
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

      notification = create_tracking_notification(request_form) || raise('Could not create W9 tracking notification')
      Delivery.new(secure_request_form: request_form, raw_token: raw_token, context: @email_context, notification_id: notification.id)
    end

    def request_form_attributes(raw_token)
      {
        vendor: vendor,
        kind: :w9_upload,
        status: :sent,
        recipient_email: recipient_email,
        public_token_digest: VendorSecureRequestForm.digest_public_token(raw_token),
        expires_at: SecureFormPolicy.expires_at,
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

    def delivery_mail_action
      latest_rejection_review.present? ? 'VendorNotificationsMailer#w9_rejected' : 'VendorNotificationsMailer#w9_upload_requested'
    end

    def delivery_channel(_delivery) = :email
    def delivery_result_locale = secure_form_locale_for(vendor)

    def suppressed_delivery_data(deliveries)
      { vendor_secure_request_form: Array(deliveries).first&.secure_request_form }.compact
    end

    def delivery_failure_data(delivery_failures, deliveries)
      super.merge(suppressed_delivery_data(deliveries), delivery_failure: delivery_failures.first)
    end

    def delivery_failure_details(forms)
      request_form = forms.first
      { vendor_id: vendor.id, vendor_secure_request_form_id: request_form.id,
        request_batch_id: request_form.request_batch_id, recipient_ids: [], template_name: delivery_template_name }
    end

    def deliver_email(delivery)
      @email_context = delivery_context_for(delivery)
      deliver_request_email!(delivery.secure_request_form, delivery.raw_token)
    end

    # Delivers to the email recorded on the request row. deliver_now keeps the
    # bearer URL out of job arguments.
    def deliver_request_email!(request_form, raw_token)
      secure_upload_url = secure_upload_url_for(raw_token)

      mailer = VendorNotificationsMailer.with(
        vendor: vendor,
        recipient_email: request_form.recipient_email,
        w9_review: latest_rejection_review,
        secure_upload_url: secure_upload_url
      )
      EmailDelivery.deliver_now!(latest_rejection_review.present? ? mailer.w9_rejected : mailer.w9_upload_requested,
                                 context: @email_context)
    end

    def secure_upload_url_for(raw_token)
      SecureFormPolicy.public_url(:secure_w9_form_url, raw_token)
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
      vendor.w9_requestable_via_secure_form?
    end

    def delivery_template_name
      latest_rejection_review.present? ? 'vendor_notifications_w9_rejected' : 'vendor_notifications_w9_upload_requested'
    end

    # A resend uses the vendor email on file now, not the one on the expired link.
    def recipient_email
      vendor.email
    end

    def message(key, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(vendor))
    end

    class CooldownActive < StandardError; end
  end
end
