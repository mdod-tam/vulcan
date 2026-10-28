# frozen_string_literal: true

module Applications
  # Secure-request issuers share the same per-recipient delivery contract.
  # Hosts retain domain validation, delivery copy, and workflow compensation.
  module SecureRequestDeliveryPolicy
    Delivery = Data.define(:secure_request_form, :raw_token, :context, :notification_id, :candidate, :proof_review) do
      def initialize(candidate: nil, proof_review: nil, **)
        super
      end
    end

    private

    def with_issuance_errors(owner)
      yield
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      issuance_conflict(owner, e)
    rescue SecureRequestIssuance::CooldownActive => e
      public_recovery ? success(public_recovery_message) : failure(message(:cooldown_active, minutes: e.minutes))
    end

    def with_recipient_issuance_errors(&)
      with_issuance_errors(application, &)
    rescue ActiveRecord::RecordNotFound, SecureRequestIssuanceIntegrity::ParticipantSetUnstable => e
      issuance_conflict(application, e)
    rescue SecureRequestIssuance::Refused => e
      failure(message(e.reason))
    end

    def issuance_conflict(owner, error)
      Rails.logger.warn("#{self.class.name} request failed for #{owner.model_name.singular} #{owner.id}: #{error.class.name}")
      failure(message(:request_conflict))
    end

    def public_recovery_message = message(:resent)

    def message(key, user: actor, **)
      I18n.t("#{self.class::MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(user))
    end

    def prepare_requests
      issuance.with_locked_context do |context|
        @application = context.application
        @actor = context.actor
        @resend_of = context.resend_of
        yield if block_given?

        candidates = issuance.resolve_recipients!(recipient_ids: recipient_ids, channel_overrides: channel_overrides)
        request_batch_id = SecureRandom.uuid
        candidates.filter_map do |candidate|
          if delivery_denied_for?(candidate)
            denied_candidates << candidate
            next
          end

          create_delivery(candidate, request_batch_id)
        end
      end
    end

    def deliver_sms(delivery)
      form = delivery.secure_request_form
      SmsService.send_message(
        form.recipient_phone,
        sms_message(secure_url_for(delivery.raw_token), form),
        sensitive: true,
        action: sms_action,
        delivery_context: delivery_context_for(delivery),
        context: { secure_request_form_id: form.id, application_id: application.id,
                   recipient_id: form.recipient_id, recipient_channel: form.recipient_channel }
      )
    end

    def authorize_delivery
      decision, @email_context = delivery_authorization(:email)
      return unless decision

      return configuration_failure(decision.reason) if decision.configuration_error?

      suppressed(decision.reason)
    end

    def delivery_authorization(channel)
      EmailDelivery.issuance(channel.to_s == 'sms' ? sms_action : delivery_mail_action, channel: channel.to_s)
    end

    def configuration_failure(reason, data = {})
      failure(I18n.t('email_delivery.configuration_error', locale: delivery_result_locale),
              data.merge(delivery_error: true, configuration_error: true, reason: reason))
    end

    def deliver_requests(deliveries)
      delivery_failures = []
      suppression_reason = nil

      Array(deliveries).each do |delivery|
        case delivery_channel(delivery).to_sym
        when :email
          deliver_email(delivery)
        when :sms
          deliver_sms(delivery)
        when :letter
          deliver_letter(delivery)
        end
        record_delivery_handoff(delivery)
      rescue ApplicationMailer::DeliverySkipped => e
        suppression_reason = e.reason
        suppress_delivery(delivery, e.reason)
      rescue StandardError => e
        report_delivery_failure(e, [delivery])
        delivery_failures << delivery_failure_context(e, [delivery])
        revoke_failed_deliveries([delivery], e)
      end

      if delivery_failures.any?
        data = delivery_failure_data(delivery_failures, deliveries)
        if (configuration = delivery_failures.find { |item| item[:configuration_error] })
          return configuration_failure(configuration[:reason], data)
        end

        return failure(message(:delivery_failed), data)
      end
      return suppressed(suppression_reason, deliveries) if suppression_reason

      success
    end

    # Transport completed. Bookkeeping failure must not revoke a link already sent.
    def record_delivery_handoff(delivery)
      Notification.find_by(id: delivery.notification_id)&.record_delivery_handoff!(
        channel: delivery_channel(delivery),
        state: delivery_channel(delivery).to_s == 'letter' ? :queued : :submitted
      )
    rescue StandardError => e
      Rails.logger.error("Secure request handoff tracking failed: #{e.class.name}")
    end

    def suppressed(reason, deliveries = [])
      failure(message(:delivery_suppressed), suppressed_delivery_data(deliveries).merge(delivery_suppressed: true, suppression_reason: reason))
    end

    def suppressed_delivery_data(_deliveries) = {}
    def delivery_result_locale = secure_form_locale_for(actor)
    def delivery_channel(delivery) = delivery.secure_request_form.recipient_channel
    def after_delivery_not_sent(_delivery); end

    def report_delivery_failure(error, deliveries)
      context = delivery_failure_context(error, deliveries)
      if Rails.respond_to?(:error)
        Rails.error.report(reportable_delivery_error(error), handled: true, context: context)
      else
        Rails.logger.error("Secure request delivery failed: #{context.inspect}")
      end
    rescue StandardError => e
      Rails.logger.error("Secure request error reporting failed: #{e.class}")
    end

    def reportable_delivery_error(error)
      StandardError.new(error.class.name)
    end

    def revoke_failed_deliveries(deliveries, error)
      Array(deliveries).each do |delivery|
        request_form = delivery.secure_request_form
        configuration_error = error.is_a?(EmailDelivery::ConfigurationError)
        if request_form&.active?
          request_form.revoke!(
            actor: actor,
            reason: configuration_error ? :delivery_configuration_error : :delivery_failure,
            metadata: { delivery_failure: delivery_failure_context(error, [delivery]) }
          )
        end
        # Keep tracking outside revoke!'s transaction so its failure does not undo revocation.
        persist_delivery_failure(delivery, error)
      rescue StandardError => e
        Rails.logger.error(
          "Secure request delivery failure cleanup failed: #{e.class.name}"
        )
      ensure
        after_delivery_not_sent(delivery) if configuration_error
      end
    end

    def persist_delivery_failure(delivery, error)
      notification = Notification.find_by(id: delivery.notification_id)
      if error.is_a?(EmailDelivery::ConfigurationError)
        notification&.mark_delivery_not_sent!(EmailDelivery::Decision.configuration_error(error.reason), channel: delivery_channel(delivery))
      else
        notification&.mark_delivery_failed!(error, channel: delivery_channel(delivery), details: delivery_failure_context(error, [delivery]))
      end
    end

    def delivery_failure_data(delivery_failures, deliveries)
      {
        secure_request_forms: Array(deliveries).map(&:secure_request_form),
        delivery_error: true,
        delivery_failures: delivery_failures,
        failed_secure_request_form_ids: delivery_failures.flat_map { |failure| failure[:secure_request_form_ids] },
        failed_recipient_ids: delivery_failures.flat_map { |failure| failure[:recipient_ids] },
        failed_recipient_channels: delivery_failures.flat_map { |failure| failure[:recipient_channels] }
      }
    end

    def delivery_failure_context(error, deliveries)
      forms = Array(deliveries).map(&:secure_request_form)
      context = {
        error_class: error.class.name,
        secure_request_form_ids: forms.map(&:id),
        recipient_channels: Array(deliveries).map { |delivery| delivery_channel(delivery).to_s }
      }.merge(delivery_failure_details(forms))
      context.merge!(configuration_error: true, reason: error.reason) if error.is_a?(EmailDelivery::ConfigurationError)
      context
    end

    def delivery_failure_details(forms)
      { application_id: application.id, recipient_ids: forms.map(&:recipient_id) }
    end

    def delivery_denied_for?(candidate)
      decision, = authorization_for(candidate)
      decision.present?
    end

    def authorization_for(candidate)
      @delivery_authorizations ||= {}
      @delivery_authorizations[[candidate.recipient.id, candidate.channel.to_s]] ||=
        delivery_authorization(candidate.channel)
    end

    def denied_candidates
      @denied_candidates ||= []
    end

    def delivery_denial
      decisions = denied_candidates.map { |candidate| authorization_for(candidate).first }.compact
      decisions.find(&:configuration_error?) || decisions.first
    end

    def delivery_configuration_error?
      delivery_denial&.configuration_error?
    end

    def delivery_denial_result(deliveries)
      data = { secure_request_forms: Array(deliveries).map(&:secure_request_form),
               failed_recipient_ids: denied_candidates.map { |candidate| candidate.recipient.id } }
      if delivery_configuration_error?
        configuration_failure(delivery_denial.reason, data)
      else
        key = deliveries.present? ? 'outbound_delivery.partial_suppression' : 'outbound_delivery.delivery_suppressed'
        failure(I18n.t(key, locale: secure_form_locale_for(actor)),
                data.merge(delivery_suppressed: true, suppression_reason: delivery_denial.reason))
      end
    end

    def delivery_context_for(delivery)
      delivery.context.merge('request_id' => "secure-request-#{delivery.secure_request_form.model_name.singular}-#{delivery.secure_request_form.id}",
                             'notification_id' => delivery.notification_id,
                             'channel' => delivery_channel(delivery))
    end

    def suppress_delivery(delivery, reason)
      request_form = delivery.secure_request_form
      SecureRequestDelivery.suppress!(request_form: request_form, notification: Notification.find_by(id: delivery.notification_id),
                                      actor: actor, reason: reason, channel: delivery_channel(delivery))
      after_delivery_not_sent(delivery)
    end
  end
end
