# frozen_string_literal: true

module Applications
  class RequestProviderInfo < BaseService
    include SecureFormLocaleResolver
    include SecureRequestDeliveryPolicy

    MESSAGE_SCOPE = 'applications.provider_info.messages'

    attr_reader :application, :actor, :recipient_ids, :channel_overrides, :resend_of, :public_recovery

    def initialize(application:, actor:, recipient_ids: nil, channel_overrides: {}, resend_of: nil, public_recovery: false)
      super()
      @application = application
      @actor = actor
      @recipient_ids = recipient_ids
      @channel_overrides = channel_overrides
      @resend_of = resend_of
      @public_recovery = public_recovery
    end

    def call
      with_recipient_issuance_errors do
        Letters::Delivery.reconcile_pending!(scope: PrintQueueItem.unreleased.where(application_id: application.id))
        deliveries = prepare_requests
        delivery_result = deliver_requests(deliveries)
        return delivery_result if delivery_result.failure?
        return delivery_denial_result(deliveries) if denied_candidates.any?

        success(message(:request_created), { secure_request_forms: deliveries.map(&:secure_request_form) })
      end
    end

    private

    def issuance
      @issuance ||= SecureRequestIssuance.new(
        application: application,
        actor: actor,
        resend_of: resend_of,
        kind: :provider_info_request,
        form_scope: :provider_info
      )
    end

    def create_delivery(candidate, request_batch_id)
      issued = issuance.replace_request!(candidate: candidate, request_batch_id: request_batch_id,
                                         notification_type: 'provider_info_requested')
      Delivery.new(secure_request_form: issued.secure_request_form, raw_token: issued.raw_token,
                   candidate: candidate, context: authorization_for(candidate).last, notification_id: issued.notification_id)
    end

    def deliver_email(delivery)
      # deliver_now keeps the raw bearer URL out of Active Job arguments.
      EmailDelivery.deliver_now!(
        ApplicationNotificationsMailer
          .provider_info_requested(application, delivery.secure_request_form, secure_url: secure_url_for(delivery.raw_token)),
        context: delivery_context_for(delivery)
      )
    end

    def delivery_mail_action = 'ApplicationNotificationsMailer#provider_info_requested'
    def sms_action = 'SmsService#provider_info'

    def deliver_letter(delivery)
      mail = ApplicationNotificationsMailer.provider_info_requested(
        application, delivery.secure_request_form, secure_url: nil, letter_recipient: delivery.candidate.address_owner
      )
      EmailDelivery.deliver_now!(mail, context: delivery_context_for(delivery))
    end

    def public_recovery_message = message(:resent, user: resend_of&.recipient || actor)

    def secure_url_for(raw_token)
      SecureFormPolicy.public_url(:secure_provider_info_form_url, raw_token)
    end

    def sms_message(secure_url, secure_request_form)
      I18n.t(
        'secure_provider_info_forms.sms.message',
        locale: secure_request_form.delivery_locale,
        secure_url: secure_url,
        hours: SecureFormPolicy.link_expiration_hours
      )
    end
  end
end
