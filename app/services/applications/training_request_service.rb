# frozen_string_literal: true

module Applications
  class TrainingRequestService < BaseService
    DUPLICATE_REQUEST_MESSAGE = 'Training session requested. A trainer will reach out soon to schedule your training.'
    ACTIVE_SESSION_MESSAGE = 'You already have a training session in progress.'
    SERVICE_WINDOW_MESSAGE = 'Training is no longer available because this application is outside the service window.'

    attr_reader :application, :current_user

    def initialize(application:, current_user:)
      super()
      @application = application
      @current_user = current_user
    end

    def call
      return failure('Only approved applications are eligible for training.') unless application.status_approved?
      return failure(SERVICE_WINDOW_MESSAGE) unless application.service_window_active?
      return failure(DUPLICATE_REQUEST_MESSAGE) if application.training_request_pending?
      return failure(ACTIVE_SESSION_MESSAGE) if application.active_training_session_present?
      return failure('You have used all of your available training sessions.') unless check_session_limit?

      application.update!(training_requested_at: Time.current)
      create_notifications
      log_request
      Application.expire_training_request_metrics_cache!
      success('Training request submitted. An administrator will contact you to schedule your session.')
    end

    private

    def check_session_limit?
      max_sessions = Policy.get('max_training_sessions') || 3
      application.training_sessions.completed_sessions.count < max_sessions
    end

    def create_notifications
      User.where(type: 'Users::Administrator').find_each do |admin|
        create_admin_notification(admin)
      end
    end

    def create_admin_notification(admin)
      # Log the audit event
      AuditEventService.log(
        action: 'training_requested',
        actor: current_user,
        auditable: application,
        metadata: notification_metadata(admin)
      )

      # Send the notification
      NotificationService.create_and_deliver!(
        type: 'training_requested',
        recipient: admin,
        actor: current_user,
        notifiable: application,
        metadata: notification_metadata(admin),
        channel: :email
      )
    rescue StandardError => e
      Rails.logger.error("Failed to notify admin #{admin.id} of training request: #{e.message}")
      # Continue with other admins even if one fails
    end

    def notification_metadata(admin)
      {
        recipient_id: admin.id,
        constituent_id: current_user.id,
        constituent_name: current_user.full_name,
        application_id: application.id
      }
    end

    def log_request
      AuditEventService.log(
        action: 'training_session_requested',
        actor: current_user,
        auditable: application,
        metadata: {
          constituent_id: current_user.id
        }
      )
    rescue StandardError => e
      Rails.logger.error("Failed to log training request: #{e.message}")
      # Don't fail the request if logging fails
    end
  end
end
