# frozen_string_literal: true

module Applications
  class RequestProviderInfo < BaseService
    include SecureFormLocaleResolver

    MESSAGE_SCOPE = 'applications.provider_info.messages'
    TEMPLATE_NAME = 'application_notifications_provider_info_requested'

    Delivery = Struct.new(:secure_request_form, :raw_token, :candidate)

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
      deliveries, result = prepare_requests

      return result if result&.failure?

      delivery_result = deliver_requests(deliveries)
      return delivery_result if delivery_result.failure?

      result
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
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

      ApplicationRecord.transaction do
        locked_recipient_ids = lock_potential_recipient_users
        if locked_recipient_ids.nil?
          result = failure(message(:request_conflict))
          raise ActiveRecord::Rollback
        end
        application.lock!

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

        unless resolved_recipients_locked?(resolved.data, locked_recipient_ids)
          result = failure(message(:request_conflict))
          raise ActiveRecord::Rollback
        end

        deliveries = create_requests_for(resolved.data)
        result = success(message(:request_created), { secure_request_forms: deliveries.map(&:secure_request_form) })
      end

      [deliveries, result]
    end

    # Merge locks users before applications. Lock every user the resolver could select,
    # then lock/reload the application and resolve again. If merge commits first the
    # recipient is now inactive; if issuance commits first the active form blocks merge.
    def lock_potential_recipient_users
      ids = potential_recipient_ids
      users = User.where(id: ids).order(:id).lock.to_a
      return if users.size != ids.size || users.any? { |user| !user.public_login_active? }

      users.map(&:id)
    end

    def potential_recipient_ids
      recipient_resolver = resend_of.present? ? resolver_for_resend : resolver
      recipient_resolver.known_recipients.filter_map(&:id).uniq
    end

    def resolved_recipients_locked?(candidates, locked_recipient_ids)
      candidates.all? { |candidate| locked_recipient_ids.include?(candidate.recipient.id) }
    end

    # resend_of takes precedence over recipient_ids; they are mutually exclusive
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
        channel_overrides: channel_overrides
      )
    end

    def resolver_for_resend
      Applications::SecureRequestRecipientResolver.new(
        application: application,
        recipient_ids: [resend_of.recipient_id],
        channel_overrides: { resend_of.recipient_id => resend_of.recipient_channel }
      )
    end

    def repair_managing_guardian_if_possible
      return success if application.managing_guardian_id.present?

      relationships = GuardianRelationship.where(dependent_id: application.user_id).to_a
      return success if relationships.empty?

      if relationships.one?
        application.update!(managing_guardian_id: relationships.first.guardian_id)
        return success
      end

      failure(message(:needs_managing_guardian))
    end

    def create_requests_for(candidates)
      request_batch_id = SecureRandom.uuid
      candidates.map do |candidate|
        ensure_cooldown_allows!(candidate)
        SecureRequestForm
          .open_provider_info_for_recipient(application_id: application.id, recipient_id: candidate.recipient.id)
          .find_each { |request_form| request_form.revoke!(actor: actor, reason: :replacement_request) }
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

      cooldown_until = latest_request.sent_at + resend_cooldown_hours.hours
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

      create_tracking_notification(secure_request_form)
      Delivery.new(secure_request_form: secure_request_form, raw_token: raw_token, candidate: candidate)
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
        public_token_digest: SecureRequestForm.digest_public_token(raw_token),
        expires_at: link_expiration_hours.hours.from_now,
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
          request_batch_id: secure_request_form.request_batch_id,
          expires_at: secure_request_form.expires_at.iso8601
        },
        channel: notification_channel_for(secure_request_form),
        audit: true,
        deliver: false
      )
    end

    def notification_channel_for(secure_request_form)
      case secure_request_form.recipient_channel
      when 'letter'
        :letter
      when 'sms'
        # NotificationService has no SMS transport in v1; SmsService owns token-safe SMS delivery.
        :email
      end || :email
    end

    def deliver_requests(deliveries)
      delivery_failures = []

      # Request rows are committed before transport begins. Attempting each
      # delivery preserves per-recipient delivery opportunities and returns
      # non-secret failure metadata for staff follow-up.
      Array(deliveries).each do |delivery|
        case delivery.secure_request_form.recipient_channel.to_sym
        when :email
          deliver_email(delivery)
        when :sms
          deliver_sms(delivery)
        when :letter
          deliver_letter(delivery)
        end
      rescue StandardError => e
        report_delivery_failure(e, [delivery])
        delivery_failures << delivery_failure_context(e, [delivery])
        revoke_failed_deliveries([delivery], e)
      end

      return failure(message(:delivery_failed), delivery_failure_data(delivery_failures, deliveries)) if delivery_failures.any?

      success
    end

    def deliver_email(delivery)
      # deliver_now is intentional: the email body contains the raw bearer URL,
      # which must not be serialized into Active Job arguments via deliver_later.
      ApplicationNotificationsMailer
        .provider_info_requested(application, delivery.secure_request_form, secure_url: secure_url_for(delivery.raw_token))
        .deliver_now
    end

    def deliver_letter(delivery)
      # deliver_now triggers the action body, which calls queue_letter_delivery
      # and returns noop_letter_delivery (a safe no-op for .deliver_now).
      ApplicationNotificationsMailer
        .provider_info_requested(application, delivery.secure_request_form, secure_url: nil)
        .deliver_now
    end

    def deliver_sms(delivery)
      secure_request_form = delivery.secure_request_form
      SmsService.send_message(
        secure_request_form.recipient_phone,
        sms_message(secure_url_for(delivery.raw_token), secure_request_form),
        sensitive: true,
        context: {
          secure_request_form_id: secure_request_form.id,
          application_id: application.id,
          recipient_id: secure_request_form.recipient_id,
          recipient_channel: secure_request_form.recipient_channel
        }
      )
    end

    def report_delivery_failure(error, deliveries)
      context = delivery_failure_context(error, deliveries)
      if Rails.respond_to?(:error)
        Rails.error.report(reportable_delivery_error(error), handled: true, context: context)
      else
        Rails.logger.error("Provider-info delivery failed: #{context.inspect}")
      end
    end

    def reportable_delivery_error(error)
      StandardError.new(sanitize_secure_error_message(error.message)).tap do |reportable_error|
        reportable_error.set_backtrace(Array(error.backtrace).map { |line| sanitize_secure_error_message(line) })
      end
    end

    def revoke_failed_deliveries(deliveries, error)
      Array(deliveries).each do |delivery|
        request_form = delivery.secure_request_form
        next unless request_form&.active?

        request_form.revoke!(
          actor: actor,
          reason: :delivery_failure,
          metadata: { delivery_failure: delivery_failure_context(error, [delivery]) }
        )
      rescue StandardError => e
        Rails.logger.error(
          "Provider-info delivery failure revocation failed: #{sanitize_secure_error_message(e.message)}"
        )
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
      {
        error_class: error.class.name,
        application_id: application.id,
        secure_request_form_ids: forms.map(&:id),
        recipient_ids: forms.map(&:recipient_id),
        recipient_channels: forms.map(&:recipient_channel)
      }
    end

    def secure_url_for(raw_token)
      options = Rails.application.config.action_mailer.default_url_options || {}
      host = options[:host]
      protocol = options[:protocol] || (Rails.env.production? ? 'https' : 'http')

      if Rails.env.production?
        raise ArgumentError, 'Secure request form host is not configured' if host.blank? || host == 'example.com'
        raise ArgumentError, 'Secure request form URLs must use HTTPS in production' unless protocol == 'https'
      end

      Rails.application.routes.url_helpers.secure_provider_info_form_url(
        token: raw_token,
        host: host,
        port: options[:port],
        protocol: protocol
      )
    end

    def sms_message(secure_url, secure_request_form)
      I18n.t(
        'secure_provider_info_forms.sms.message',
        locale: secure_form_locale_for(secure_request_form.recipient),
        secure_url: secure_url,
        hours: link_expiration_hours
      )
    end

    def link_expiration_hours
      Policy.get('secure_form_link_expiration_hours') || 48
    end

    def resend_cooldown_hours
      Policy.get('secure_form_resend_cooldown_hours') || 1
    end

    def message(key, user: actor, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(user))
    end

    class CooldownActive < StandardError; end
  end
end
