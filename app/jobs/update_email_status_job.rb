# frozen_string_literal: true

# Refreshes provider status for a notification's pollable delivery attempts. The notification's own message_id is never
# treated as a provider id.
class UpdateEmailStatusJob < ApplicationJob
  queue_as :default

  def perform(notification_id)
    EmailDeliveryAttempt.pollable.where(notification_id: notification_id).find_each do |attempt|
      PostmarkEmailTracker.refresh(attempt)
    end
  end
end
