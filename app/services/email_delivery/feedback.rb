# frozen_string_literal: true

module EmailDelivery
  # Only normalized facts enter persistence. Provider diagnostics and bodies never do.
  class Feedback
    Fact = Data.define(:message_id, :recipient, :kind, :at, :event_id, :correlation_id, :category)
    class Invalid < StandardError; end
    KINDS = { 'Delivery' => 'delivered', 'Bounce' => 'bounced', 'SpamComplaint' => 'complained', 'Open' => 'opened' }.freeze
    CATEGORIES = %w[HardBounce SoftBounce Transient DNSFailure SpamNotification SpamComplaint Blocked ManualDeactivation Unsubscribe].freeze

    def self.webhook(payload)
      raise Invalid unless payload.is_a?(Hash) && (payload['Metadata'].nil? || payload['Metadata'].is_a?(Hash))

      kind = KINDS[payload['RecordType']]
      raise Invalid unless kind

      at = payload[{ 'delivered' => 'DeliveredAt', 'bounced' => 'BouncedAt', 'complained' => 'BouncedAt', 'opened' => 'ReceivedAt' }.fetch(kind)]
      fact(message_id: payload['MessageID'], recipient: payload['Recipient'] || payload['Email'], kind: kind, at: at,
           event_id: payload['ID'], correlation_id: payload['Metadata'].to_h['delivery_attempt'], category: payload['Type'])
    end

    # postmark 1.25.1 transforms top-level keys only. Nested MessageEvents retain string keys.
    def self.sdk(message, attempt)
      raise Invalid unless message[:message_id] == attempt.provider_message_id

      Array(message[:message_events]).filter_map do |event|
        kind = { 'Delivered' => 'delivered', 'Bounced' => 'bounced', 'SpamComplaint' => 'complained', 'Opened' => 'opened', 'Transient' => 'delayed' }[event['Type']]
        next unless kind

        recipient = event['Recipient']
        next unless recipient.present? && EmailDeliveryAttempt.recipient_key(recipient) == attempt.recipient_key

        details = event['Details'].is_a?(Hash) ? event['Details'] : {}
        fact(message_id: attempt.provider_message_id, recipient: recipient, kind: kind, at: event['ReceivedAt'],
             event_id: details['BounceID'], correlation_id: nil, category: details['Type'])
      end
    end

    def self.fact(**attributes)
      message_id, recipient, kind, at, event_id, correlation_id, category = attributes.values_at(:message_id, :recipient, :kind, :at, :event_id, :correlation_id,
                                                                                                 :category)
      validate_message_id!(message_id)
      raise Invalid unless recipient.is_a?(String) && recipient.include?('@') && recipient.size <= 320
      raise Invalid unless at.is_a?(String) && at.size <= 60

      validate_event_identity!(event_id, correlation_id)

      time = Time.iso8601(at)
      raise Invalid if time > 1.day.from_now

      Fact.new(message_id: message_id, recipient: recipient.strip.downcase, kind: kind, at: time,
               event_id: event_id.to_s.presence, correlation_id: correlation_id.presence,
               category: CATEGORIES.include?(category) ? category : 'Other')
    rescue ArgumentError, TypeError
      raise Invalid
    end

    def self.validate_event_identity!(event_id, correlation_id)
      raise Invalid unless event_id.nil? || ((event_id.is_a?(String) || event_id.is_a?(Integer)) && event_id.to_s.size <= 200)
      raise Invalid unless correlation_id.nil? || (correlation_id.is_a?(String) && correlation_id.size <= 100)
    end
    private_class_method :validate_event_identity!

    def self.validate_message_id!(value)
      raise Invalid unless value.is_a?(String) && value.present? && value.size <= 200
    end
    private_class_method :validate_message_id!

    def self.apply(fact, server_id: ENV.fetch('POSTMARK_SERVER_ID', 'default'))
      scope = EmailDeliveryAttempt.where(server_id: server_id, recipient_key: EmailDeliveryAttempt.recipient_key(fact.recipient))
      attempt = scope.find_by(provider_message_id: fact.message_id)
      attempt ||= scope.find_by(correlation_id: fact.correlation_id) if fact.correlation_id
      return :unmatched unless attempt

      attempt.with_lock do
        raise Invalid if attempt.provider_message_id.present? && attempt.provider_message_id != fact.message_id

        key = Digest::SHA256.hexdigest([fact.kind, fact.event_id || fact.at.iso8601(6)].join(':'))
        unless attempt.email_delivery_receipts.exists?(event_key: key)
          attempt.email_delivery_receipts.create!(event_key: key, kind: fact.kind, occurred_at: fact.at)
          attributes = { provider_message_id: fact.message_id, state: 'accepted', feedback_at: Time.current }
          column = "#{fact.kind}_at"
          attributes[column] = [attempt.public_send(column), fact.at].compact.min
          attributes[:bounce_category] = fact.category if fact.kind == 'bounced'
          attempt.update!(attributes)
        end
        record_bounce(attempt) if attempt.bounced_at && !attempt.bounce_event_id
      end
      :applied
    end

    def self.record_bounce(attempt)
      actor = PublicAuditActor.system_audit_actor_or_report('email_bounced')
      return unless actor

      event = Event.create!(user: actor, action: 'email_bounced', auditable: attempt.origin || attempt.notification,
                            metadata: { email_delivery_attempt_id: attempt.id, bounce_category: attempt.bounce_category,
                                        bounced_at: attempt.bounced_at.iso8601 })
      attempt.update!(bounce_event: event)
    end
    private_class_method :record_bounce
  end
end
