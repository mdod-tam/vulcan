# frozen_string_literal: true

# Handles operations related to training management
# This includes trainer assignment and training session scheduling
module TrainingManagement
  extend ActiveSupport::Concern

  # Assigns a trainer to this application
  # @param trainer [Trainer] The trainer to assign
  # @return [Boolean] True if the trainer was assigned successfully
  def assign_trainer!(trainer)
    unless service_window_active?
      errors.add(:base, :training_service_window)
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

      NotificationService.create_and_deliver!(
        type: 'trainer_assigned',
        recipient: trainer,
        actor: Current.user,
        notifiable: training_session,
        metadata: {
          application_id: id,
          trainer_id: trainer.id
        },
        channel: :email
      )
    end
    true
  rescue ::ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to assign trainer: #{e.message}"
    errors.add(:base, e.message)
    false
  end
end
