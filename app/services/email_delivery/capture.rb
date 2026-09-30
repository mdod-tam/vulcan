# frozen_string_literal: true

module EmailDelivery
  # One envelope may have several recipients. Persist its whole group before transport.
  class Capture
    REQUEST_KEYS = {
      'secure_request_form_id' => SecureRequestForm,
      'medical_provider_secure_request_form_id' => MedicalProviderSecureRequestForm,
      'vendor_secure_request_form_id' => VendorSecureRequestForm
    }.freeze

    def initialize(message:, context:, subject: nil, recipient: nil, contacts: {})
      @message = message
      @context = context
      @subject = subject
      @recipient = recipient
      @contacts = contacts
      @attempts = []
    end

    def deliver
      return unless claim

      @message.metadata = @message.metadata.to_h.merge('delivery_attempt' => @context.fetch('delivery_correlation_id'))
      yield
      record_acceptance
    rescue StandardError => e
      if @message['X-PM-Message-Id'].present?
        report_tracking_failure(e)
      else
        record_failure(e)
        raise RetryableFailure, e.class.name if RetryableFailure.transient?(e) && @attempts.any? && @attempts.all? { |attempt| attempt.reload.retryable? }

        raise
      end
    end

    private

    def claim
      correlation = @context.fetch('delivery_correlation_id')
      return false if EmailDeliveryAttempt.replay_blocked?(@context)

      @server_id = EmailDelivery.postmark_server_id!

      notification = Notification.find_by(id: @context['notification_id'] || @context['provider_notification_id'])
      origin = request_origin(notification) || @subject || notification&.notifiable
      identity = delivery_identity(origin, notification)
      EmailDeliveryAttempt.transaction do
        # Serialize the envelope, including retries whose rebuilt destination has changed.
        lock_envelope(correlation)
        existing = EmailDeliveryAttempt.where(correlation_id: correlation).order(:recipient_key).lock.to_a
        addresses = Array(@message.destinations).map(&:downcase).uniq.sort
        @attempts = if existing.any?
                      reclaim_failed_attempts(existing, addresses)
                    else
                      addresses.map { |address| EmailDeliveryAttempt.create!(attempt_attributes(address, correlation, notification, origin, identity)) }
                    end
      end
      @attempts.any?
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def reclaim_failed_attempts(existing, addresses)
      return [] unless existing.all?(&:retryable?) && existing.map(&:destination).sort == addresses && existing.all? { |attempt| attempt.server_id == @server_id }

      existing.each { |attempt| attempt.update!(state: 'unknown', attempted_at: Time.current) }
      existing
    end

    def lock_envelope(correlation)
      lock_key = Digest::SHA256.digest(correlation).unpack1('q>')
      bind = ActiveRecord::Relation::QueryAttribute.new('lock_key', lock_key, ActiveRecord::Type::Integer.new(limit: 8))
      EmailDeliveryAttempt.connection.exec_query('SELECT pg_advisory_xact_lock($1)', 'Email envelope lock', [bind])
    end

    def attempt_attributes(address, correlation, notification, origin, identity)
      primary = address == @message.to&.first&.downcase
      explicit_request = REQUEST_KEYS.value?(origin.class)
      contact = (identity if primary && explicit_request) || @contacts[address] || (identity if primary) || {}
      { correlation_id: correlation, recipient_key: EmailDeliveryAttempt.recipient_key(address), destination: address,
        server_id: @server_id, mail_action: @context.fetch('mail_action'), attempted_at: Time.current,
        notification: notification, origin: origin, application: identity[:application],
        recipient: contact[:recipient], delivery_owner: contact[:owner] }
    end

    def delivery_identity(origin, notification)
      recipient = origin.respond_to?(:recipient) ? origin.recipient : notification&.recipient || @recipient
      recipient = nil if @context['mail_action'].start_with?('MedicalProviderMailer#')
      application = origin.is_a?(Application) ? origin : (origin.application if origin.respond_to?(:application))
      { recipient: recipient, owner: destination_owner(origin, recipient), application: application }
    end

    def destination_owner(origin, recipient)
      return origin.delivery_owner if origin.respond_to?(:delivery_owner)
      return origin.vendor if origin.is_a?(VendorSecureRequestForm)
      return unless recipient
      return unless EmailDeliveryAttempt.recipient_key(recipient.email) == EmailDeliveryAttempt.recipient_key(@message.to&.first)

      recipient
    end

    def request_origin(notification)
      metadata = notification&.metadata.to_h
      pair = REQUEST_KEYS.find { |key, _klass| metadata[key].present? }
      pair&.last&.find_by(id: metadata[pair.first])
    end

    def record_acceptance
      provider_id = @message['X-PM-Message-Id']&.value.presence
      @attempts.each do |attempt|
        attempt.with_lock do
          attributes = { rfc_message_id: @message.message_id }
          if provider_id
            raise ArgumentError, 'Provider identity mismatch' if attempt.provider_message_id.present? && attempt.provider_message_id != provider_id

            attributes.merge!(provider_message_id: provider_id, accepted_at: attempt.accepted_at || Time.current, state: 'accepted')
          end
          attempt.update!(attributes)
        end
      end
    rescue StandardError => e
      report_tracking_failure(e)
    end

    def record_failure(error)
      return unless RetryableFailure.rejected?(error)

      @attempts.each do |attempt|
        attempt.with_lock do
          attempt.update!(state: 'failed') if attempt.provider_message_id.blank? && attempt.accepted_at.nil? && attempt.feedback_at.nil?
        end
      end
    rescue StandardError => e
      report_tracking_failure(e)
      Rails.logger.error("Email delivery transport failed: #{error.class.name}")
    end

    def report_tracking_failure(error)
      Rails.logger.error("Email delivery tracking failed after handoff: #{error.class.name}")
      ActiveSupport::Notifications.instrument('tracking_failed.email_delivery', error_class: error.class.name)
    rescue StandardError => e
      Rails.logger.error("Email tracking instrumentation failed: #{e.class.name}")
    end
  end
end
