# frozen_string_literal: true

module EmailDelivery
  # Records an email that was not sent. Stored through audit events, which stay visible while
  # email is off; one record per request, so reprocessing the same job does not add another.
  # These paths are reachable from public requests (a password reset while email is off), so the
  # actor is looked up only: a missing or non-admin system account is logged, never created or promoted.
  module Outcome
    AUDIT_ACTOR_MISSING = 'email_delivery_audit_actor_missing'

    SUPPRESSED = 'email_delivery_suppressed'
    CONFIGURATION_ERROR = 'email_delivery_configuration_error'

    def self.record_not_sent(decision, context:, mail_action:)
      Current.denial_decision = decision
      MedicalProviderNotifier.record_fallback_outcome(context, status: decision.outcome, reason: decision.reason) if context&.dig('provider_notification_id')
      action = decision.configuration_error? ? CONFIGURATION_ERROR : SUPPRESSED
      request_id = context&.dig('request_id')
      ActiveSupport::Notifications.instrument("#{action}.email_delivery", reason: decision.reason, mail_action: mail_action)
      log(decision, action, mail_action, request_id)
      mark_originating_notification(context) { |notification| notification.mark_delivery_not_sent!(decision, channel: context&.dig('channel') || :email) }
      return if request_id.present? && recorded?(action, request_id)
      return unless (actor = audit_actor(action, mail_action))

      Event.create!(
        user: actor,
        action: action,
        metadata: { mail_action: mail_action, reason: decision.reason, request_id: request_id }.compact
      )
    rescue StandardError => e
      Rails.logger.error("EmailDelivery: could not record #{action} for #{mail_action}: #{e.class}")
    end

    ENQUEUE_FAILED = 'email_delivery_enqueue_failed'

    # The email was requested but never reached the queue. Nothing was sent or claimed as queued.
    def self.record_enqueue_failure(error, context:, mail_action:)
      MedicalProviderNotifier.record_fallback_outcome(context, status: :enqueue_failed, reason: error.class.name) if context&.dig('provider_notification_id')
      request_id = context&.dig('request_id')
      ActiveSupport::Notifications.instrument("#{ENQUEUE_FAILED}.email_delivery", mail_action: mail_action)
      Rails.logger.error("EmailDelivery: #{ENQUEUE_FAILED} #{mail_action} #{error.class} request=#{request_id}")
      mark_originating_notification(context) { |notification| notification.mark_delivery_enqueue_failed!(error) }
      return unless (actor = audit_actor(ENQUEUE_FAILED, mail_action))

      Event.create!(
        user: actor,
        action: ENQUEUE_FAILED,
        metadata: { mail_action: mail_action, error_class: error.class.name, request_id: request_id }.compact
      )
    rescue StandardError => e
      Rails.logger.error("EmailDelivery: could not record #{ENQUEUE_FAILED} for #{mail_action}: #{e.class}")
    end

    # The email was being sent for a notification: record the outcome on it, whenever it happened.
    def self.mark_originating_notification(context)
      notification = Notification.find_by(id: context&.dig('notification_id'))
      return if notification.nil?

      yield notification
    rescue StandardError => e
      Rails.logger.error("EmailDelivery: could not mark notification #{notification&.id} as not sent: #{e.class}")
    end
    private_class_method :mark_originating_notification

    def self.audit_actor(action, mail_action)
      actor = PublicAuditActor.system_audit_actor
      return actor if actor

      ActiveSupport::Notifications.instrument("#{AUDIT_ACTOR_MISSING}.email_delivery", action: action, mail_action: mail_action)
      Rails.logger.error("EmailDelivery: #{action} for #{mail_action} not recorded: no configured system audit actor " \
                         "(#{PublicAuditActor::SYSTEM_AUDIT_EMAIL})")
      nil
    end
    private_class_method :audit_actor

    def self.recorded?(action, request_id)
      Event.where(action: action).with_metadata(:request_id, request_id).exists?
    end
    private_class_method :recorded?

    def self.log(decision, action, mail_action, request_id)
      level = decision.configuration_error? ? :error : :info
      Rails.logger.public_send(level, "EmailDelivery: #{action} #{mail_action} reason=#{decision.reason} request=#{request_id}")
    end
    private_class_method :log
  end
end
