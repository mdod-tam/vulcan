# frozen_string_literal: true

module NotificationPreloading
  extend ActiveSupport::Concern

  TRAINING_SESSION_ACTIONS = %w[
    training_scheduled
    training_rescheduled
    training_cancelled
    training_completed
  ].freeze

  private

  def preload_notification_message_dependencies(notifications)
    preload_training_session_notification_dependencies(notifications)
    trainer_assigned_apps = notifications
                            .select { |notification| notification.action == 'trainer_assigned' }
                            .filter_map(&:notifiable)
                            .grep(Application)

    return if trainer_assigned_apps.blank?

    ActiveRecord::Associations::Preloader.new(
      records: trainer_assigned_apps,
      associations: %i[user training_sessions]
    ).call
  end

  def preload_training_session_notification_dependencies(notifications)
    training_sessions = notifications
                        .select { |notification| TRAINING_SESSION_ACTIONS.include?(notification.action) }
                        .filter_map(&:notifiable)
                        .grep(TrainingSession)

    return if training_sessions.blank?

    ActiveRecord::Associations::Preloader.new(
      records: training_sessions,
      associations: [:trainer, { application: :user }]
    ).call
  end
end
