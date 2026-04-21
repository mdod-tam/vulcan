# frozen_string_literal: true

class TrainingSessionNotifier
  attr_reader :training_session

  def initialize(training_session)
    @training_session = training_session
  end

  def deliver_all
    return unless should_send_notification?
    return unless notification_action

    ActiveRecord::Base.transaction do
      create_consolidated_notification
    end
  end

  private

  def should_send_notification?
    training_session.saved_change_to_status? ||
      training_session.saved_change_to_scheduled_for? ||
      training_session.saved_change_to_completed_at?
  end

  def create_consolidated_notification
    # Send the notification (audit flag is false by default, so it only logs the notification delivery event)
    NotificationService.create_and_deliver!(
      type: notification_action,
      recipient: training_session.constituent,
      actor: training_session.trainer,
      notifiable: training_session,
      metadata: notification_metadata,
      channel: :email
    )
  rescue StandardError => e
    Rails.logger.error "Failed to send training session notification via NotificationService: #{e.message}"
    # Don't re-raise - notification errors shouldn't fail the training session update
  end

  def notification_action
    case training_session.status
    when 'scheduled', 'confirmed' then 'training_scheduled'
    when 'completed' then 'training_completed'
    when 'cancelled' then 'training_cancelled'
    when 'no_show' then 'training_missed'
    end
  end

  def notification_metadata
    {
      training_session_id: training_session.id,
      application_id: training_session.application.id,
      status: training_session.status,
      scheduled_for: training_session.scheduled_for&.iso8601,
      completed_at: training_session.completed_at&.iso8601,
      trainer_name: training_session.trainer.full_name,
      timestamp: Time.current.iso8601
    }
  end
end
