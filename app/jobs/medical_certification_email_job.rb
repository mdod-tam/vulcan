# frozen_string_literal: true

class MedicalCertificationEmailJob < ApplicationJob
  queue_as :default
  retry_on Net::SMTPError, wait: :exponentially_longer, attempts: 3

  def perform(application_id:, timestamp:, notification_id: nil)
    Rails.logger.info "Processing disability certification email for application #{application_id}"

    application = Application.find(application_id)

    notification = resolve_notification(application, timestamp, notification_id)
    send_request_email(application, timestamp, notification)

    Rails.logger.info "Successfully sent disability certification email for application #{application_id}"
  rescue StandardError => e
    handle_job_error(application_id, e, notification)
    raise
  end

  private

  def resolve_notification(application, timestamp, notification_id)
    return Notification.find_by(id: notification_id) if notification_id.present?

    recent_notification_for(application) || create_notification(application, timestamp)
  end

  def recent_notification_for(application)
    Notification
      .medical_certification_requests
      .where(notifiable: application)
      .where('created_at > ?', 1.minute.ago)
      .order(created_at: :desc)
      .first
  end

  def send_request_email(application, timestamp, notification)
    MedicalProviderMailer.with(
      application: application,
      timestamp: timestamp,
      notification_id: notification&.id
    ).request_certification.deliver_now
  end

  def handle_job_error(application_id, error, notification)
    Rails.logger.error "Failed to send certification email for application #{application_id}: #{error.message}"
    Rails.logger.error error.backtrace.join("\n")

    return if notification.blank?

    notification.update_metadata!('error_message', error.message)
    notification.update(delivery_status: 'error')
  end

  def create_notification(application, timestamp)
    recipient = User.admins.first || User.first
    return nil unless recipient

    actor = current_actor || recipient

    # Log the audit event
    AuditEventService.log(
      action: 'medical_certification_requested_notification_sent',
      actor: actor,
      auditable: application,
      metadata: {
        recipient_id: recipient.id,
        provider: application.medical_provider_name,
        provider_email: application.medical_provider_email
      }
    )

    # Create record-only notification; email delivery is owned by this job
    NotificationService.create_and_deliver!(
      type: 'medical_certification_requested',
      recipient: recipient,
      actor: actor,
      notifiable: application,
      metadata: {
        timestamp: timestamp,
        provider: application.medical_provider_name,
        provider_email: application.medical_provider_email
      },
      channel: :email,
      deliver: false
    )
  end

  def current_actor
    Current.user
  rescue StandardError
    nil
  end
end
