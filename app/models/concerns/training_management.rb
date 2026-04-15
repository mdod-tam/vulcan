# frozen_string_literal: true

# Handles operations related to training management
# This includes trainer assignment and training session scheduling
module TrainingManagement
  extend ActiveSupport::Concern

  TRAINING_SERVICE_WINDOW_ERROR = 'This application is outside the service window for training services.'
  private_constant :TRAINING_SERVICE_WINDOW_ERROR

  # Assigns a trainer to this application
  # @param trainer [Trainer] The trainer to assign
  # @return [Boolean] True if the trainer was assigned successfully
  def assign_trainer!(trainer)
    unless service_window_active?
      errors.add(:base, TRAINING_SERVICE_WINDOW_ERROR)
      return false
    end

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
    end
    true
  rescue ::ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to assign trainer: #{e.message}"
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
