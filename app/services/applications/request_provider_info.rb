# frozen_string_literal: true

module Applications
  class RequestProviderInfo < BaseService
    include SecureFormLocaleResolver
    include SecureRequestDeliveryPolicy

    MESSAGE_SCOPE = 'applications.provider_info.messages'
    TEMPLATE_NAME = 'application_notifications_provider_info_requested'

    Delivery = Struct.new(:secure_request_form, :raw_token, :candidate, :context, :notification_id)

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
      Letters::Delivery.reconcile_pending!(scope: PrintQueueItem.unreleased.where(application_id: application.id))
      deliveries, result = prepare_requests

      return result if result&.failure?

      delivery_result = deliver_requests(deliveries)
      return delivery_result if delivery_result.failure?

      return delivery_denial_result(deliveries) if denied_candidates.any?

      result
    rescue ActiveRecord::RecordNotUnique,
           ActiveRecord::RecordInvalid,
           ActiveRecord::RecordNotFound,
           Applications::SecureRequestIssuanceIntegrity::ParticipantSetUnstable => e
      Rails.logger.warn("Provider-info request failed for application #{application.id}: #{e.message}")
      failure(message(:request_conflict))
    rescue CooldownActive => e
      return success(message(:resent, user: resend_of&.recipient || actor)) if public_recovery

      failure(e.message)
    end

    private

    def prepare_requests
      deliveries = nil
      result = nil

      issuance_integrity.with_locked_context do |context|
        install_locked_context!(context)
        unless secure_request_actor_eligible?
          result = failure(message(:recipient_no_longer_eligible))
          raise ActiveRecord::Rollback
        end

        repair_result = repair_managing_guardian_if_possible
        unless repair_result.success?
          result = repair_result
          raise ActiveRecord::Rollback
        end

        resolved = resolve_recipients
        unless resolved.success?
          result = resolved
          raise ActiveRecord::Rollback
        end

        resolved.data.each do |candidate|
          candidate.recipient = context.locked_users.fetch(candidate.recipient.id)
        end
        unless secure_request_recipients_eligible?(resolved.data)
          result = failure(message(:recipient_no_longer_eligible))
          raise ActiveRecord::Rollback
        end

        deliveries = create_requests_for(resolved.data)
        result = if deliveries.empty? && denied_candidates.any?
                   delivery_denial_result(deliveries)
                 else
                   success(message(:request_created), { secure_request_forms: deliveries.map(&:secure_request_form) })
                 end
      end

      [deliveries, result]
    end

    def issuance_integrity
      Applications::SecureRequestIssuanceIntegrity.new(
        application: application,
        actor: actor,
        resend_of: resend_of
      )
    end

    def install_locked_context!(context)
      @application = context.application
      @actor = context.actor
      @resend_of = context.resend_of
      @secure_request_known_recipients = context.known_recipients
      @secure_request_guardian_relationships = context.guardian_relationships
    end

    def secure_request_actor_eligible?
      actor.admin? && actor.public_login_active?
    end

    # Locked recipients and delivery owners must meet delivery policy,
    # including guardians who supply a dependent's contact or address.
    def secure_request_recipients_eligible?(candidates)
      candidates.all?(&:delivery_participants_eligible?)
    end

    def resolve_recipients
      candidates = if resend_of.present?
                     resolver_for_resend.resolve
                   else
                     resolver.resolve
                   end

      return failure(message(:unknown_recipient)) if recipient_ids.present? && resend_of.blank? &&
                                                     candidates.size != Array(recipient_ids).compact_blank.size

      failure_candidate = candidates.find(&:failure_reason)
      return failure(message(failure_candidate.failure_reason)) if failure_candidate

      return failure(message(:no_recipient)) if candidates.blank?

      success(nil, candidates)
    end

    def resolver
      Applications::SecureRequestRecipientResolver.new(
        application: application,
        recipient_ids: recipient_ids,
        channel_overrides: channel_overrides,
        known_recipients: @secure_request_known_recipients,
        guardian_relationships: @secure_request_guardian_relationships
      )
    end

    def resolver_for_resend
      Applications::SecureRequestRecipientResolver.new(
        application: application,
        recipient_ids: [resend_of.recipient_id],
        channel_overrides: { resend_of.recipient_id => resend_of.recipient_channel },
        known_recipients: @secure_request_known_recipients,
        guardian_relationships: @secure_request_guardian_relationships
      )
    end

    def repair_managing_guardian_if_possible
      return success if application.managing_guardian_id.present?

      relationships = @secure_request_guardian_relationships
      return success if relationships.empty?

      if relationships.one?
        application.update!(managing_guardian_id: relationships.first.guardian_id)
        return success
      end

      failure(message(:needs_managing_guardian))
    end

    # Refuse each denied channel before token creation; eligible recipients still proceed.
    def create_requests_for(candidates)
      request_batch_id = SecureRandom.uuid
      candidates.filter_map do |candidate|
        if delivery_denied_for?(candidate)
          denied_candidates << candidate
          next
        end

        ensure_cooldown_allows!(candidate)
        SecureRequestForm
          .open_provider_info_for_recipient(application_id: application.id, recipient_id: candidate.recipient.id)
          .order(:id)
          .lock
          .each { |request_form| request_form.revoke!(actor: actor, reason: :replacement_request) }
        create_delivery(candidate, request_batch_id)
      end
    end

    def ensure_cooldown_allows!(candidate)
      latest_request = SecureRequestForm
                       .provider_info
                       .status_sent
                       .where(application: application, recipient: candidate.recipient)
                       .where(submitted_at: nil, revoked_at: nil)
                       .order(sent_at: :desc)
                       .first
      return if latest_request.blank?

      cooldown_until = latest_request.sent_at + SecureFormPolicy.resend_cooldown_hours.hours
      return if cooldown_until <= Time.current

      minutes = ((cooldown_until - Time.current) / 60.0).ceil
      raise CooldownActive, message(:cooldown_active, minutes: minutes)
    end

    def create_delivery(candidate, request_batch_id)
      attempts = 0
      secure_request_form = nil

      begin
        attempts += 1
        raw_token = SecureRequestForm.generate_public_token
        ApplicationRecord.transaction(requires_new: true) do
          secure_request_form = SecureRequestForm.create!(secure_request_form_attributes(candidate, request_batch_id, raw_token))
        end
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < 2

        raise
      end

      notification = create_tracking_notification(secure_request_form)
      Delivery.new(secure_request_form: secure_request_form, raw_token: raw_token, candidate: candidate, context: authorization_for(candidate).last,
                   notification_id: notification&.id)
    end

    def secure_request_form_attributes(candidate, request_batch_id, raw_token)
      {
        application: application,
        kind: :provider_info_request,
        status: :sent,
        request_batch_id: request_batch_id,
        recipient: candidate.recipient,
        recipient_email: candidate.email,
        recipient_phone: candidate.phone,
        recipient_channel: candidate.channel,
        recipient_role: candidate.recipient_role,
        recipient_relationship_type: candidate.recipient_relationship_type,
        delivery_owner: candidate.delivery_owner,
        delivery_source: candidate.delivery_source&.to_s,
        public_token_digest: SecureRequestForm.digest_public_token(raw_token),
        expires_at: SecureFormPolicy.expires_at,
        sent_at: Time.current,
        requested_by: actor
      }
    end

    def create_tracking_notification(secure_request_form)
      NotificationService.create_and_deliver!(
        type: 'provider_info_requested',
        recipient: secure_request_form.recipient,
        actor: actor,
        notifiable: application,
        metadata: {
          secure_request_form_id: secure_request_form.id,
          application_id: application.id,
          recipient_id: secure_request_form.recipient_id,
          recipient_role: secure_request_form.recipient_role,
          recipient_channel: secure_request_form.recipient_channel,
          requested_recipient_channel: secure_request_form.recipient_channel,
          delivery_owner_id: secure_request_form.delivery_owner_id,
          delivery_source: secure_request_form.delivery_source,
          request_batch_id: secure_request_form.request_batch_id,
          expires_at: secure_request_form.expires_at.iso8601
        },
        channel: notification_channel_for(secure_request_form),
        audit: true,
        deliver: false
      )
    end

    def deliver_email(delivery)
      # deliver_now keeps the raw bearer URL out of Active Job arguments.
      EmailDelivery.deliver_now!(
        ApplicationNotificationsMailer
          .provider_info_requested(application, delivery.secure_request_form, secure_url: secure_url_for(delivery.raw_token)),
        context: delivery_context_for(delivery)
      )
    end

    def delivery_requested? = true
    def delivery_mail_action = 'ApplicationNotificationsMailer#provider_info_requested'
    def sms_action = 'SmsService#provider_info'

    def deliver_letter(delivery)
      mail = ApplicationNotificationsMailer.provider_info_requested(
        application, delivery.secure_request_form, secure_url: nil, letter_recipient: delivery.candidate.address_owner
      )
      EmailDelivery.deliver_now!(mail, context: delivery_context_for(delivery))
    end

    def deliver_sms(delivery)
      secure_request_form = delivery.secure_request_form
      SmsService.send_message(
        secure_request_form.recipient_phone,
        sms_message(secure_url_for(delivery.raw_token), secure_request_form),
        sensitive: true,
        action: sms_action,
        delivery_context: delivery_context_for(delivery),
        context: {
          secure_request_form_id: secure_request_form.id,
          application_id: application.id,
          recipient_id: secure_request_form.recipient_id,
          recipient_channel: secure_request_form.recipient_channel
        }
      )
    end

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

    def message(key, user: actor, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(user))
    end

    class CooldownActive < StandardError; end
  end
end
