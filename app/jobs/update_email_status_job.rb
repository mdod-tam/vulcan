# frozen_string_literal: true

# Job for tracking and updating email delivery status for notifications.
# Handles medical certification request notifications by
# fetching status from Postmark and updating notification records.
class UpdateEmailStatusJob < ApplicationJob
  queue_as :default

  # The tracker returns this when it could not reach Postmark; it is not a message status.
  TRACKER_ERROR = 'error'

  def perform(notification_id)
    notification = find_and_validate_notification(notification_id)
    return unless notification
    return if terminal?(notification)

    begin
      status = PostmarkEmailTracker.fetch_status(notification.message_id)
      apply_status(notification, status)
      schedule_follow_up_if_needed(notification_id, notification)
    rescue StandardError => e
      handle_error(notification, notification_id, e)
    end
  end

  private

  def find_and_validate_notification(notification_id)
    notification = Notification.find_by(id: notification_id)
    return unless notification
    return if notification.message_id.blank?
    return unless notification.action == 'medical_certification_requested'

    notification
  end

  # A suppressed or failed notification keeps its outcome; a late poll cannot overwrite it.
  def terminal?(notification)
    notification.suppressed_delivery_status? || notification.error_delivery_status? ||
      notification.metadata.to_h.key?('delivery_suppressed')
  end

  # The provider was asked outside any lock. Apply its answer against the row as it is now, so an
  # overlapping poll or a suppression written meanwhile is never overwritten by a stale response.
  def apply_status(notification, status)
    message_id = notification.message_id
    notification.with_lock do
      next if terminal?(notification) || notification.message_id != message_id

      if status[:status] == TRACKER_ERROR
        notification.update!(metadata: notification.metadata.to_h.merge('status_check_failed_at' => Time.current.iso8601))
        next
      end

      notification.update!(**status_attributes(notification, status))
    end
  end

  def status_attributes(notification, status)
    result = EmailDelivery::ProviderStatus.normalize(
      raw_status: status[:status], delivered_at: status[:delivered_at], opened_at: status[:opened_at]
    )
    Rails.logger.warn("Unrecognized Postmark status #{status[:status].inspect} for notification #{notification.id}") unless result.recognized
    new_status = EmailDelivery::ProviderStatus.advance(notification.delivery_status, result.status)

    metadata = notification.metadata.to_h
    metadata['provider_status'] = status[:status].to_s if new_status == result.status || !result.recognized
    metadata['provider_status_unrecognized'] = true unless result.recognized
    metadata['email_details'] = status[:open_details] if status[:open_details].present? && notification.opened_at.nil?

    {
      delivery_status: new_status,
      delivered_at: notification.delivered_at || status[:delivered_at],
      opened_at: notification.opened_at || status[:opened_at],
      metadata: metadata
    }
  end

  def schedule_follow_up_if_needed(notification_id, notification)
    return if notification.opened_at.present? || terminal?(notification)

    self.class.set(wait: 24.hours).perform_later(notification_id)
  end

  def handle_error(notification, notification_id, error)
    Rails.logger.error("Error updating email status for notification #{notification_id}: #{error.message}")
    notification.with_lock do
      next if terminal?(notification)

      notification.update!(
        delivery_status: 'error',
        metadata: notification.metadata.to_h.merge(
          'delivery_error' => { 'message' => error.message, 'error_class' => error.class.name }
        )
      )
    end
  end
end
