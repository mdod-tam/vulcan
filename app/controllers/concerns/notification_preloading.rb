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
    notification_list = notifications.to_a

    preload_application_notification_dependencies(notification_list)
    preload_training_session_notification_dependencies(notification_list)
    trainer_assigned_apps = notification_list
                            .select { |notification| notification.action == 'trainer_assigned' }
                            .filter_map(&:notifiable)
                            .grep(Application)

    return if trainer_assigned_apps.blank?

    ActiveRecord::Associations::Preloader.new(
      records: trainer_assigned_apps,
      associations: %i[user training_sessions]
    ).call
  end

  def preload_application_notification_dependencies(notifications)
    proof_reviews = notifications
                    .filter_map(&:notifiable)
                    .grep(ProofReview)

    if proof_reviews.any?
      ActiveRecord::Associations::Preloader.new(
        records: proof_reviews,
        associations: { application: :user }
      ).call
    end

    applications = notifications
                   .filter_map { |notification| notification_application_for_preload(notification) }
                   .uniq
    return if applications.blank?

    ActiveRecord::Associations::Preloader.new(
      records: applications,
      associations: :user
    ).call

    proof_resubmission_applications = notifications
                                      .select { |notification| notification.action == 'proof_resubmission_requested' }
                                      .filter_map { |notification| notification_application_for_preload(notification) }
                                      .uniq
    return if proof_resubmission_applications.blank?

    ActiveRecord::Associations::Preloader.new(
      records: proof_resubmission_applications,
      associations: :proof_reviews
    ).call
  end

  def notification_application_for_preload(notification)
    notifiable = notification.notifiable
    return notifiable if notifiable.is_a?(Application)
    return notifiable.application if notifiable.respond_to?(:application)

    nil
  end

  def preload_training_session_notification_dependencies(notifications)
    training_sessions = notifications
                        .select { |notification| TRAINING_SESSION_ACTIONS.include?(notification.action) }
                        .filter_map(&:notifiable)
                        .grep(TrainingSession)

    return if training_sessions.blank?

    ActiveRecord::Associations::Preloader.new(
      records: training_sessions,
      associations: [{ application: :user }]
    ).call
  end
end
