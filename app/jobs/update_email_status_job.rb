# frozen_string_literal: true

# Preserves the existing notification-ID job contract; never interprets legacy message_id as a provider ID.
class UpdateEmailStatusJob < ApplicationJob
  queue_as :default

  def perform(notification_id)
    EmailDeliveryAttempt.pollable.where(notification_id: notification_id).find_each do |attempt|
      PostmarkEmailTracker.refresh(attempt)
    end
  end
end
