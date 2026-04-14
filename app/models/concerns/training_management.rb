# frozen_string_literal: true

# Handles operations related to training management
# This includes trainer assignment and training session scheduling
module TrainingManagement
  extend ActiveSupport::Concern

  # Assigns a trainer to this application
  # @param trainer [Trainer] The trainer to assign
  # @return [Boolean] True if the trainer was assigned successfully
  def assign_trainer!(trainer)
    with_lock do
      training_session = training_sessions.create!(
        trainer: trainer,
        status: :requested
        # No default scheduled_for - will be set by trainer after coordinating with constituent
      )

      # Create event for audit logging
      AuditEventService.log(
        action: 'trainer_assigned',
        actor: Current.user,
        auditable: self,
        metadata: {
          trainer_id: trainer.id,
          trainer_name: trainer.full_name
        }
      )

      # Create system notification for the constituent
      NotificationService.create_and_deliver!(
        type: 'trainer_assigned',
        recipient: user,
        actor: Current.user,
        notifiable: self,
        metadata: {
          application_id: id
        },
        channel: :email
      )

      # Send email notification to the trainer with constituent contact info
      TrainingSessionNotificationsMailer.trainer_assigned(training_session).deliver_later

      Application.expire_training_request_metrics_cache!
    end
    true
  rescue ::ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to assign trainer: #{e.message}"
    false
  end

  # Schedules a training session
  # @param trainer [Trainer] The trainer to schedule with
  # @param scheduled_for [DateTime] The date and time of the training
  # @return [Boolean] True if the training was scheduled successfully
  def schedule_training!(trainer:, scheduled_for:)
    with_lock do
      training_sessions.create!(
        trainer: trainer,
        scheduled_for: scheduled_for,
        status: :scheduled
      )
    end
    true
  rescue ::ActiveRecord::RecordInvalid => e
    Rails.logger.error "[Application #{id}] Failed to schedule training: #{e.message}"
    errors.add(:base, e.message)
    false
  end

  private

  def create_system_notification!(recipient:, actor:, action:)
    # Use NotificationService for centralized notification creation
    NotificationService.create_and_deliver!(
      type: action,
      recipient: recipient,
      actor: actor,
      notifiable: self,
      metadata: {
        application_id: id
      },
      channel: :email
    )
  end
end
