# frozen_string_literal: true

# Handles operations related to training management
# This includes trainer assignment and training session scheduling
module TrainingManagement
  extend ActiveSupport::Concern

  def max_training_sessions
    Policy.max_training_sessions
  end

  def completed_training_sessions_count
    training_sessions.completed_sessions.count
  end

  def remaining_training_sessions
    [max_training_sessions - completed_training_sessions_count, 0].max
  end

  def training_session_quota_exhausted?
    completed_training_sessions_count >= max_training_sessions
  end

  def latest_training_session
    training_sessions.order(created_at: :desc, id: :desc).first
  end

  def latest_training_follow_up_session
    latest_session = latest_training_session
    return unless latest_session&.needs_followup?
    return if active_training_session_present?
    return unless remaining_training_sessions.positive?

    latest_session
  end

  # Assigns a trainer to this application
  # @param trainer [Trainer] The trainer to assign
  # @return [Boolean] True if the trainer was assigned successfully
  def assign_trainer!(trainer)
    unless service_window_active?
      errors.add(:base, :training_service_window)
      return false
    end

    if training_session_quota_exhausted?
      errors.add(:base, :training_session_quota_exhausted)
      return false
    end

    with_lock do
      if active_training_session_present?
        errors.add(:base, :training_session_active)
        return false
      end

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

      Application.expire_training_request_metrics_cache!
    end
    true
  rescue ::ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to assign trainer: #{e.message}"
    errors.add(:base, e.message)
    false
  end

  def unassign_trainer!(actor:, reason: nil)
    training_session = active_training_session
    unless training_session
      errors.add(:base, :training_session_not_active)
      return false
    end

    cancellation_reason = reason.presence || 'Trainer assignment removed by administrator.'

    with_lock do
      update_attributes = {
        status: :cancelled,
        cancelled_at: Time.current,
        cancellation_reason: cancellation_reason,
        notes: nil,
        no_show_notes: nil
      }
      update_attributes[:cancellation_initiator] = :admin if TrainingSession.cancellation_initiator_column?

      training_session.update!(update_attributes)

      AuditEventService.log(
        action: 'trainer_unassigned',
        actor: actor,
        auditable: self,
        metadata: {
          training_session_id: training_session.id,
          trainer_id: training_session.trainer_id,
          trainer_name: training_session.trainer.full_name,
          cancellation_reason: cancellation_reason
        }
      )

      Application.expire_training_request_metrics_cache!
    end
    true
  rescue ::ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to unassign trainer: #{e.message}"
    errors.add(:base, e.message)
    false
  end
end
