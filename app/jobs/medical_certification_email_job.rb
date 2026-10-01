# frozen_string_literal: true

class MedicalCertificationEmailJob < ApplicationJob
  include EmailDeliveryContextJob

  queue_as :default
  self.enqueue_after_transaction_commit = true
  self.email_delivery_mail_action = 'MedicalProviderMailer#request_certification'

  def email_delivery_params
    arguments.first.to_h.slice(:notification_id, 'notification_id')
  end

  def perform(application_id:, timestamp:, notification_id:)
    Rails.logger.info "Processing disability certification email for application #{application_id}"

    application = Application.find(application_id)

    notification = resolve_notification(application, timestamp, notification_id)
    send_request_email(application, timestamp, notification)

    Rails.logger.info "Successfully sent disability certification email for application #{application_id}"
  rescue ApplicationMailer::DeliverySkipped => e
    # Intentionally not sent: terminal, not retried, and not an error.
    notification&.mark_delivery_suppressed!(e.reason)
    delivery_not_sent
    Rails.logger.info "Disability certification email for application #{application_id} suppressed: #{e.reason}"
  rescue StandardError => e
    handle_job_error(application_id, e, notification)
    raise
  end

  def delivery_not_sent
    notification = Notification.find_by(id: email_delivery_context&.dig('notification_id'))
    Applications::MedicalCertificationService.restore_unsent_request(notification) if notification
  end

  private

  def resolve_notification(application, _timestamp, notification_id)
    # Legacy queued requests are rejected by the context callback; never bind to a newer notice.
    return unless notification_id

    Notification.find_by!(id: notification_id, notifiable: application, action: 'medical_certification_requested')
  end

  def send_request_email(application, timestamp, notification)
    EmailDelivery.deliver_now!(
      MedicalProviderMailer.with(
        application: application,
        timestamp: timestamp,
        notification_id: notification&.id
      ).request_certification
    )
  end

  def handle_job_error(application_id, error, notification)
    Rails.logger.error "Failed to send certification email for application #{application_id}: #{error.message}"
    Rails.logger.error error.backtrace.join("\n")

    return if notification.blank? || notification.email_delivery_attempts.exists?

    if error.is_a?(EmailDelivery::ConfigurationError)
      notification.mark_delivery_not_sent!(EmailDelivery::Decision.configuration_error(error.reason))
      delivery_not_sent
      return
    end

    notification.mark_delivery_failed!(error)
  end
end
