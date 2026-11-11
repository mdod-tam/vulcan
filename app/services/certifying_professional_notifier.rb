# frozen_string_literal: true

class CertifyingProfessionalNotifier
  include SecureErrorSanitizer

  REJECTION_ACTION = 'disability_certification_rejected'
  EMAIL_METHOD = 'email'
  EMAIL_ACTION = 'CertifyingProfessionalMailer#certification_rejected'
  UNAVAILABLE_MESSAGE = 'Automatic provider notification is unavailable without an email address. Contact the provider manually.'

  attr_reader :application

  def initialize(application)
    @application = application
  end

  # Attempts provider notification for a rejected certification.
  # Provider notices use email. DocuSeal remains an explicit admin action.
  # @param rejection_reason [String] The reason for rejection
  # @param admin [User] The admin who rejected the certification
  # @param notification_id [Integer, nil] Existing rejection notification id to enrich with delivery metadata
  # @param secure_upload_url [String, nil] Tokenized upload URL for email delivery only
  # @return [Hash] Transport outcome and independent notification tracking status
  def send_certification_rejection_notice(rejection_reason:, admin:, notification_id: nil, secure_upload_url: nil)
    Rails.logger.info "Notifying certifying professional about certification rejection for Application ID: #{application.id}"

    @delivery_context = EmailDelivery::Policy.capture(mail_action: EMAIL_ACTION, params: { notification_id: notification_id })
    delivery_result = if email_available?
                        notify_by_email(rejection_reason, admin, secure_upload_url: secure_upload_url)
                      else
                        failure_result(outcome: :unavailable, error: UNAVAILABLE_MESSAGE)
                      end

    handle_delivery_result(delivery_result, notification_id: notification_id)
  end

  private

  def email_available?
    application.certifying_professional_email.present?
  end

  def handle_delivery_result(delivery_result, notification_id: nil)
    update_notification_metadata(delivery_result, notification_id: notification_id)
    delivery_result.merge(tracking_status: notification_id ? :recorded : :not_requested)
  rescue StandardError => e
    Rails.logger.error "Failed to handle delivery result for Application ID: #{application.id} - #{e.class.name}"
    delivery_result.merge(tracking_status: :failed, tracking_error: e.class.name)
  end

  def update_notification_metadata(delivery_result, notification_id: nil)
    notification = find_rejection_notification(notification_id)

    return unless notification_id

    raise ActiveRecord::RecordNotFound, 'Rejection notification not found' unless notification

    notification.with_lock do
      metadata = (notification.metadata || {}).merge(
        'notification_methods' => notification_methods, 'provider_notification_attempted_at' => Time.current.iso8601,
        'provider_delivery_outcome' => delivery_result[:outcome].to_s
      )
      if delivery_result[:success]
        metadata['delivery_method'] = delivery_result[:method]
        metadata.delete('provider_notification_error')
        metadata['message_id'] = delivery_result[:message_id] if delivery_result[:message_id].present?
      elsif delivery_result[:error].present?
        metadata['provider_notification_error'] = 'Provider notification could not be sent.'
      end
      notification.update!(metadata: metadata)
    end
  end

  def find_rejection_notification(notification_id)
    return unless notification_id

    Notification.find_by(id: notification_id, notifiable: application, action: REJECTION_ACTION)
  end

  def failure_result(error: nil, method: nil, outcome: :failed)
    sanitized_error = error.present? ? sanitize_secure_error_message(error) : nil
    {
      success: false,
      method: method,
      outcome: outcome,
      error: sanitized_error
    }.compact
  end

  # A secure URL requires immediate delivery. Other notices use the queue.
  # @param rejection_reason [String] The reason for rejection
  # @param admin [User] The admin who rejected the certification
  # @param secure_upload_url [String, nil] Tokenized upload URL for corrected certification upload
  # @return [Hash] Delivery result hash
  def notify_by_email(rejection_reason, admin, secure_upload_url: nil)
    EmailDelivery.verify!(EMAIL_ACTION, context: @delivery_context, channel: :email)
    mail = CertifyingProfessionalMailer.with(
      application: application,
      rejection_reason: rejection_reason,
      admin: admin,
      secure_upload_url: secure_upload_url
    ).certification_rejected

    if secure_upload_url.present?
      EmailDelivery.deliver_now!(mail, context: @delivery_context)
      { success: true, method: EMAIL_METHOD, outcome: :submitted, message_id: mail['X-PM-Message-Id']&.value }
    else
      outcome = EmailDelivery.deliver_later(mail, context: @delivery_context)
      { success: %i[queued deferred].include?(outcome), method: EMAIL_METHOD, outcome: outcome }
    end
  rescue ApplicationMailer::DeliverySkipped, EmailDelivery::ConfigurationError => e
    refusal_result(EMAIL_METHOD, e)
  rescue StandardError => e
    Rails.logger.error("Provider email failed for application #{application.id}: #{e.class.name}")
    failure_result(method: EMAIL_METHOD, error: e.message)
  end

  def refusal_result(method, error)
    { success: false, method: method,
      outcome: error.is_a?(EmailDelivery::ConfigurationError) ? :configuration_error : :suppressed,
      reason: error.reason, error: error.message }
  end

  # @return [Array<String>] The available notification methods
  def notification_methods
    email_available? ? [EMAIL_METHOD] : []
  end
end
