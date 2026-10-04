# frozen_string_literal: true

class MedicalProviderNotifier
  include SecureErrorSanitizer

  REJECTION_ACTION = 'medical_certification_rejected'
  FAX_METHOD = 'fax'
  EMAIL_METHOD = 'email'
  EMAIL_ACTION = 'MedicalProviderMailer#certification_rejected'
  FAX_ACTION = 'FaxService#certification_rejected'
  FAX_FAILURES = %w[failed no-answer busy canceled].freeze
  FAX_TERMINAL = (FAX_FAILURES + %w[delivered]).freeze

  attr_reader :application

  def initialize(application)
    @application = application
  end

  # Attempts provider notification for a rejected certification.
  # FaxService refuses fax delivery. DocuSeal remains an explicit admin action.
  # @param rejection_reason [String] The reason for rejection
  # @param admin [User] The admin who rejected the certification
  # @param notification_id [Integer, nil] Existing rejection notification id to enrich with delivery metadata
  # @param secure_upload_url [String, nil] Tokenized upload URL for email delivery only
  # @return [Boolean] True if email submission or enqueue succeeds and metadata persistence does not fail
  def send_certification_rejection_notice(rejection_reason:, admin:, notification_id: nil, secure_upload_url: nil)
    Rails.logger.info "Notifying medical provider about certification rejection for Application ID: #{application.id}"

    @delivery_contexts = { 'email' => EmailDelivery::Policy.capture(mail_action: EMAIL_ACTION, params: { notification_id: notification_id }) }
    delivery_result = if email_available?
                        notify_by_email(rejection_reason, admin, secure_upload_url: secure_upload_url)
                      else
                        failure_result(method: FAX_METHOD, error: FaxService::UNAVAILABLE_MESSAGE)
                      end

    handle_delivery_result(delivery_result, notification_id: notification_id)
  end

  def receive_fax_status(notification, fax_sid:, status:)
    return unless (%w[queued processing sending received] + FAX_TERMINAL).include?(status)

    context = nil
    blob_id = nil
    notification.with_lock do
      metadata = notification.metadata || {}
      return unless metadata['fax_sid'] == fax_sid
      return if FAX_TERMINAL.include?(metadata['fax_status_details'])

      metadata['fax_status_details'] = status
      metadata['fax_status'] = FAX_FAILURES.include?(status) ? 'failed' : status
      metadata['fax_status_updated_at'] = Time.current.iso8601
      context = claim_callback_fallback(metadata, notification, fax_sid) if FAX_FAILURES.include?(status)
      blob_id = metadata['blob_id'] if FAX_TERMINAL.include?(status)
      notification.update!(fax_status_attributes(metadata, status))
    end
    # Release the notification lock before queue or provider I/O.
    # A crash after the claim leaves a visible attempt. Duplicate callbacks cannot replay that claim.
    queue_callback_fallback(notification, context) if context
    ActiveStorage::Blob.find_by(id: blob_id)&.purge_later if blob_id
  end

  def fax_status_attributes(metadata, status)
    attributes = { metadata: metadata }
    attributes[:delivery_status] = status == 'delivered' ? :delivered : :error if FAX_TERMINAL.include?(status)
    attributes
  end
  private :fax_status_attributes

  # Called only while the matching notification is locked.
  def claim_callback_fallback(metadata, notification, fax_sid)
    return unless email_available? && metadata['email_fallback'].blank?

    original = metadata.dig('provider_delivery_contexts', 'email')
    unless original
      metadata['email_fallback'] = { 'status' => 'suppressed', 'reason' => 'legacy_context_missing' }
      return
    end
    context = original.except('notification_id').merge('provider_notification_id' => notification.id,
                                                       'fax_sid' => fax_sid, 'request_id' => "fax-fallback:#{fax_sid}")
    metadata['email_fallback'] = { 'status' => 'claimed', 'request_id' => context['request_id'], 'claimed_at' => Time.current.iso8601 }
    context
  end
  private :claim_callback_fallback

  def self.record_fallback_outcome(context, status:, reason: nil)
    notification = Notification.find_by(id: context&.dig('provider_notification_id'))
    return unless notification

    notification.with_lock do
      metadata = notification.metadata || {}
      next unless metadata['fax_sid'] == context['fax_sid']

      fallback = metadata['email_fallback']
      next unless fallback && fallback['request_id'] == context['request_id']
      next if %w[suppressed configuration_error enqueue_failed submitted].include?(fallback['status'])

      fallback.merge!('status' => status.to_s, 'reason' => reason, 'updated_at' => Time.current.iso8601)
      notification.update!(metadata: metadata)
    end
  end

  def queue_callback_fallback(notification, context)
    reason = notification.metadata['rejection_reason'] || application.medical_certification_rejection_reason
    mail = MedicalProviderMailer.with(application: application, admin: notification.actor, rejection_reason: reason).certification_rejected
    outcome = EmailDelivery.deliver_later(mail, context: context)
    self.class.record_fallback_outcome(context, status: outcome)
  rescue StandardError => e
    self.class.record_fallback_outcome(context, status: :enqueue_failed, reason: e.class.name)
    EmailDelivery::Outcome.record_enqueue_failure(e, context: context, mail_action: EMAIL_ACTION)
  end

  private

  def email_available?
    application.medical_provider_email.present?
  end

  def handle_delivery_result(delivery_result, notification_id: nil)
    update_notification_metadata(delivery_result, notification_id: notification_id)
    delivery_result[:success]
  rescue StandardError => e
    Rails.logger.error "Failed to handle delivery result for Application ID: #{application.id} - #{sanitize_secure_error_message(e.message)}"
    false
  end

  def update_notification_metadata(delivery_result, notification_id: nil)
    notification = find_rejection_notification(notification_id)

    return unless notification

    notification.with_lock do
      metadata = (notification.metadata || {}).merge(
        'notification_methods' => notification_methods, 'provider_notification_attempted_at' => Time.current.iso8601,
        'provider_delivery_contexts' => @delivery_contexts
      )
      if delivery_result[:success]
        metadata['delivery_method'] = delivery_result[:method]
        metadata['provider_delivery_outcome'] = delivery_result[:outcome].to_s
        apply_success_metadata(metadata, delivery_result)
      elsif delivery_result[:error].present?
        metadata['provider_notification_error'] = sanitize_secure_error_message(delivery_result[:error])
      end
      notification.update!(metadata: metadata)
    end
  end

  def find_rejection_notification(notification_id)
    return unless notification_id

    Notification.find_by(id: notification_id, notifiable: application, action: REJECTION_ACTION)
  end

  def apply_success_metadata(metadata, delivery_result)
    case delivery_result[:method]
    when FAX_METHOD
      metadata['fax_sid'] = delivery_result[:fax_sid] if delivery_result[:fax_sid].present?
      metadata['blob_id'] = delivery_result[:blob_id] if delivery_result[:blob_id].present?
    when EMAIL_METHOD
      metadata['message_id'] = delivery_result[:message_id] if delivery_result[:message_id].present?
      metadata['email_fallback_from'] = delivery_result[:fallback_from] if delivery_result[:fallback_from].present?
    end
  end

  def failure_result(error: nil, method: nil)
    sanitized_error = error.present? ? sanitize_secure_error_message(error) : nil
    {
      success: false,
      method: method,
      error: sanitized_error
    }.compact
  end

  # A secure URL requires immediate delivery. Other notices use the queue.
  # @param rejection_reason [String] The reason for rejection
  # @param admin [User] The admin who rejected the certification
  # @param secure_upload_url [String, nil] Tokenized upload URL for corrected certification upload
  # @return [Hash] Delivery result hash
  def notify_by_email(rejection_reason, admin, secure_upload_url: nil)
    EmailDelivery.verify!(EMAIL_ACTION, context: @delivery_contexts.fetch('email'), channel: :email)
    mail = MedicalProviderMailer.with(
      application: application,
      rejection_reason: rejection_reason,
      admin: admin,
      secure_upload_url: secure_upload_url
    ).certification_rejected

    if secure_upload_url.present?
      EmailDelivery.deliver_now!(mail, context: @delivery_contexts.fetch('email'))
      { success: true, method: EMAIL_METHOD, outcome: :submitted, message_id: mail['X-PM-Message-Id']&.value }
    else
      outcome = EmailDelivery.deliver_later(mail, context: @delivery_contexts.fetch('email'))
      { success: %i[queued deferred].include?(outcome), method: EMAIL_METHOD, outcome: outcome }
    end
  rescue ApplicationMailer::DeliverySkipped, EmailDelivery::ConfigurationError => e
    refusal_result(EMAIL_METHOD, e)
  rescue StandardError => e
    Rails.logger.error("Provider email failed for application #{application.id}: #{sanitize_secure_error_message(e.message)}")
    failure_result(method: EMAIL_METHOD, error: e.message)
  end

  def refusal_result(method, error)
    { success: false, method: method,
      outcome: error.is_a?(EmailDelivery::ConfigurationError) ? :configuration_error : :suppressed,
      reason: error.reason, error: error.message }
  end

  # Fax is unavailable, so only email can appear here.
  # @return [Array<String>] The available notification methods
  def notification_methods
    methods = []
    methods << EMAIL_METHOD if email_available?
    methods
  end
end
