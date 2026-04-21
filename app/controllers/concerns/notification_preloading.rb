# frozen_string_literal: true

module NotificationPreloading
  extend ActiveSupport::Concern

  private

  def preload_notification_message_dependencies(notifications)
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
end
