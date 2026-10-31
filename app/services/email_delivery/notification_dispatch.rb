# frozen_string_literal: true

module EmailDelivery
  # Adapts notification actions to mailers and records their actual delivery route.
  class NotificationDispatch
    def initialize(notification, channel:, context: nil)
      @notification = notification
      @channel = channel
      @context = context
    end

    def call
      notification = @notification
      channel = @channel
      return false unless NotificationService::VALID_CHANNELS.include?(channel)

      # SMS tracking creates a record here. Secure-request owners call SmsService.
      if channel == :sms
        notification.mark_delivery_not_sent!(EmailDelivery::Decision.configuration_error(:sms_requires_delivery_owner), channel: :sms)
        return false
      end

      if Catalog.notification_action(notification.action)&.audit_only?
        Rails.logger.info "NotificationService: No email for '#{notification.action}' (audit-only action) — Notification ##{notification.id}"
        persist_delivery_routing_metadata(notification, actual_delivery_channel: 'none', delivery_route_reason: 'no_email_action')
        return true
      end

      enforce_delivery_contracts!(notification)

      mailer_class, method_name = resolve_mailer(notification)
      unless mailer_class && method_name
        error_message = "No mailer configured for action: #{notification.action}"
        Rails.logger.error "NotificationService: #{error_message} for Notification ##{notification.id}"
        handle_delivery_error(notification, StandardError.new(error_message), channel)
        return false
      end

      actual_delivery_channel, delivery_route_reason = send_notification_email(
        notification, mailer_class, method_name, requested_channel: channel
      )

      persist_delivery_routing_metadata(
        notification,
        actual_delivery_channel: actual_delivery_channel,
        delivery_route_reason: delivery_route_reason
      )

      ActiveSupport::Notifications.instrument(
        'notification_service.deliver',
        notification: notification,
        channel: channel,
        actual_delivery_channel: actual_delivery_channel
      )
      !notification.local_delivery_outcome?
    rescue StandardError => e
      ActiveSupport::Notifications.instrument 'notification_service.error', notification: notification, error_class: e.class.name, stage: 'delivery', channel: channel
      handle_delivery_error(notification, e, channel)
      false
    end

    private

    def enforce_delivery_contracts!(notification)
      valid = case notification.action
              when 'account_created'
                notification.recipient.is_a?(User)
              when 'disability_certification_not_provided'
                notification.notifiable.is_a?(Application) && notification.actor.present?
              else
                true
              end
      raise ArgumentError, "Notification contract violated for '#{notification.action}'" unless valid
    end

    def send_notification_email(notification, mailer_class, method_name, requested_channel:)
      state = { notification_id: notification.id }
      state.merge!(context: @context, queued: true) if @context
      EmailDelivery::Current.set(state) do
        process_notification_mail(notification, mailer_class, method_name, requested_channel: requested_channel)
      end
    rescue ApplicationMailer::DeliverySkipped, EmailDelivery::ConfigurationError => e
      decision = e.is_a?(EmailDelivery::ConfigurationError) ? EmailDelivery::Decision.configuration_error(e.reason) : EmailDelivery::Decision.suppressed(e.reason)
      notification.mark_delivery_not_sent!(decision, channel: inferred_actual_delivery_channel(notification))
      ['none', notification.reload.metadata['delivery_route_reason']]
    end

    def process_notification_mail(notification, mailer_class, method_name, requested_channel:)
      mail_delivery = build_mail_delivery(notification, mailer_class, method_name)
      actual_delivery_channel = resolve_actual_delivery_channel(mail_delivery, notification: notification)
      explicit_reason = mail_delivery.is_a?(ApplicationMailer::NoopDelivery) ? mail_delivery.reason : nil
      delivery_route_reason = explicit_reason.presence ||
                              delivery_route_reason_for(notification, requested_channel, actual_delivery_channel)

      raise StandardError, "Mailer '#{mailer_class}' method '#{method_name}' returned an invalid delivery object" unless mail_delivery.respond_to?(:deliver_later)

      outcome = queue_mail_delivery(mail_delivery)
      redact_temp_password(notification) if notification.metadata&.dig('temp_password').present?
      raise StandardError, "Mail job for '#{notification.action}' could not be queued" if outcome == :enqueue_failed

      if %i[suppressed configuration_error].include?(outcome)
        notification.reload # The outcome already records the refusal. Preserve its routing metadata.
        return ['none', notification.metadata['delivery_route_reason']]
      end

      [actual_delivery_channel, delivery_route_reason]
    end

    # :queued means the adapter accepted the job. :deferred awaits transaction commit.
    # Neither outcome confirms delivery. EmailDelivery maps a refused enqueue to an outcome symbol.
    def queue_mail_delivery(mail_delivery)
      return EmailDelivery.deliver_later(mail_delivery) if mail_delivery.is_a?(ActionMailer::MessageDelivery)

      mail_delivery.deliver_later
      :queued
    end

    # The catalog owns each action's argument shape. This method supplies the arguments.
    def build_mail_delivery(notification, mailer_class, method_name)
      case EmailDelivery::Catalog.notification_action(notification.action)&.adapter
      when :recipient
        mailer_class.public_send(method_name, notification.recipient)
      when :proof_attached
        application = notification.notifiable
        proof_type = notification.metadata&.dig('proof_type').presence ||
                     notification.action.delete_suffix('_proof_attached')
        mailer_class.public_send(method_name, application, proof_type)
      when :vendor_params
        mailer_class.with(vendor: notification.notifiable).public_send(method_name)
      when :voucher_params
        mailer_class.with(voucher: notification.notifiable).public_send(method_name)
      when :assignment
        mailer_class.with(recipient: notification.recipient, assignment: notification.notifiable,
                          operation_id: notification.metadata&.dig('operation_id')).public_send(method_name)
      when :notifiable
        mailer_class.public_send(method_name, notification.notifiable)
      else
        mailer_class.public_send(method_name, notification.notifiable, notification)
      end
    end

    def resolve_actual_delivery_channel(mail_delivery, notification:)
      if mail_delivery.is_a?(ApplicationMailer::NoopDelivery)
        return mail_delivery.channel if mail_delivery.channel.present?

        return 'letter'
      end

      return inferred_actual_delivery_channel(notification) if mail_delivery.is_a?(ActionMailer::MessageDelivery)
      return inferred_actual_delivery_channel(notification) if mail_delivery.respond_to?(:deliver_later)

      'unknown'
    end

    def inferred_actual_delivery_channel(notification)
      return 'email' if Catalog.notification_action(notification.action)&.routing == :email_only
      return 'letter' if letter_preference_route?(notification)

      'email'
    end

    def letter_preference_route?(notification)
      return false unless Catalog.notification_action(notification.action)&.routing == :preference

      EmailDelivery::Routing.prefers_letter?(notification.recipient)
    end

    def delivery_route_reason_for(notification, requested_channel, actual_delivery_channel)
      return 'email_only' if Catalog.notification_action(notification.action)&.routing == :email_only

      resolve_delivery_route_reason(
        requested_channel: requested_channel,
        actual_delivery_channel: actual_delivery_channel
      )
    end

    def resolve_delivery_route_reason(requested_channel:, actual_delivery_channel:)
      requested = requested_channel.to_s
      return 'requested_channel' if actual_delivery_channel == requested
      return 'preference' if actual_delivery_channel == 'letter'

      'mailer_override'
    end

    def persist_delivery_routing_metadata(notification, actual_delivery_channel:, delivery_route_reason:)
      notification.with_lock do
        unless notification.local_delivery_outcome?
          notification.update!(metadata: notification.metadata.to_h.merge(
            'actual_delivery_channel' => actual_delivery_channel.to_s,
            'delivery_route_reason' => delivery_route_reason.to_s
          ))
        end
      end
    rescue StandardError => e
      Rails.logger.warn "NotificationService: Failed to persist routing metadata for Notification ##{notification.id}: #{e.class.name}"
    end

    def redact_temp_password(notification)
      notification.update_metadata!('temp_password', '[REDACTED]')
    rescue StandardError => e
      Rails.logger.warn "NotificationService: Failed to redact temp_password for Notification ##{notification.id}: #{e.class.name}"
    end

    def resolve_mailer(notification)
      entry = Catalog.notification_action(notification.action)
      return [nil, nil] unless entry&.mail_action

      mailer, action = entry.mail_action.split('#')
      [mailer.constantize, action.to_sym]
    end

    def handle_delivery_error(notification, error, channel)
      Rails.logger.error "NotificationService: Delivery via #{channel} failed for Notification ##{notification.id}: #{error.class.name}"
      notification.mark_delivery_failed!(error, channel: channel)
    rescue StandardError => e
      Rails.logger.error "NotificationService: Failed persisting delivery error for Notification ##{notification.id}: #{e.class.name}"
    end
  end
end
