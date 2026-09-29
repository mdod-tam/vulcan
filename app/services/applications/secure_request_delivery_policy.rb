# frozen_string_literal: true

module Applications
  # Proof and provider-info issuance share the same per-recipient delivery contract.
  # The hosts retain recipient resolution, request creation, token handling and workflow rules.
  module SecureRequestDeliveryPolicy
    private

    def delivery_denied_for?(candidate)
      return false unless delivery_requested?

      decision, = authorization_for(candidate)
      decision.present?
    end

    def authorization_for(candidate)
      @delivery_authorizations ||= {}
      @delivery_authorizations[[candidate.recipient.id, candidate.channel.to_s]] ||=
        EmailDelivery.issuance(candidate.channel.to_s == 'sms' ? sms_action : delivery_mail_action, channel: candidate.channel.to_s)
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
        failure(I18n.t('email_delivery.configuration_error', locale: secure_form_locale_for(actor)),
                data.merge(delivery_error: true, configuration_error: true, reason: delivery_denial.reason))
      else
        key = deliveries.present? ? 'outbound_delivery.partial_suppression' : 'outbound_delivery.delivery_suppressed'
        failure(I18n.t(key, locale: secure_form_locale_for(actor)),
                data.merge(delivery_suppressed: true, suppression_reason: delivery_denial.reason))
      end
    end

    def delivery_context_for(delivery)
      delivery.context.merge('request_id' => "secure-request-#{delivery.secure_request_form.id}",
                             'notification_id' => delivery.notification_id,
                             'channel' => delivery.secure_request_form.recipient_channel)
    end

    def notification_channel_for(request_form)
      request_form.recipient_channel.to_sym
    end

    def suppress_delivery(delivery, reason)
      request_form = delivery.secure_request_form
      SecureRequestDelivery.suppress!(request_form: request_form, notification: Notification.find_by(id: delivery.notification_id),
                                      actor: actor, reason: reason, channel: request_form.recipient_channel)
    end
  end
end
