# frozen_string_literal: true

module Applications
  class TrainingRequestService < BaseService
    MESSAGE_SCOPE = 'applications.training_requests.messages'

    attr_reader :application, :current_user

    def initialize(application:, current_user:)
      super()
      @application = application
      @current_user = current_user
    end

    def call
      outcomes = []
      covered = false
      application.with_lock do
        validate_request!
        application.update!(training_requested_at: Time.current)
        AuditEventService.log(
          action: 'training_session_requested', actor: current_user, auditable: application,
          metadata: { constituent_id: application.user_id, application_id: application.id }
        )
        covered = application.assigned_trainer&.assignable_trainer? || false
        # A covering trainer who lost training access cannot take the request, so the admin queue gets it.
        audience = covered ? 'assigned_trainer' : 'assignment_queue_admin'
        recipients = covered ? [application.assigned_trainer] : User.admins.to_a
        ActiveRecord.after_all_transactions_commit do
          recipients.each { |recipient| outcomes << notify(recipient, audience: audience) }
          Reports::AdminDashboardMetrics.expire!
        end
      end
      success(message(covered ? :submitted_covered : :submitted), { notification_outcomes: outcomes })
    rescue ArgumentError => e
      failure(e.message)
    rescue ActiveRecord::RecordInvalid
      failure(message(:ineligible))
    end

    private

    def validate_request!
      raise ArgumentError, message(:ineligible) unless application.accessible_by?(current_user) && application.status_approved?
      raise ArgumentError, message(:service_window) unless application.service_window_active?
      raise ArgumentError, message(:duplicate_pending) if application.training_request_pending?
      raise ArgumentError, message(:active_session) if application.active_training_session_present?
      raise ArgumentError, message(:quota_exhausted) if application.training_session_quota_exhausted?
    end

    def notify(recipient, audience:)
      notification = NotificationService.create_and_deliver!(
        type: 'training_requested', recipient: recipient, actor: current_user, notifiable: application,
        metadata: { recipient_id: recipient.id, recipient_audience: audience, constituent_id: application.user_id,
                    application_id: application.id }, channel: :email
      )
      NotificationService.delivery_outcome(notification)
    rescue StandardError => e
      Rails.logger.error("Training request notification failed (application_id=#{application.id}, recipient_id=#{recipient.id}, error_class=#{e.class.name})")
      :failed
    end

    def message(key)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", locale: message_locale)
    end

    def message_locale
      locale = if current_user.respond_to?(:effective_locale)
                 current_user.effective_locale
               elsif current_user.respond_to?(:locale)
                 current_user.locale
               end
      locale.presence || I18n.locale
    end
  end
end
