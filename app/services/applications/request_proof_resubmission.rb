# frozen_string_literal: true

module Applications
  class RequestProofResubmission < BaseService
    include SecureFormLocaleResolver

    MESSAGE_SCOPE = 'applications.proof_resubmission.messages'
    PROOF_KIND_BY_TYPE = {
      id: :id_proof_resubmission,
      residency: :residency_proof_resubmission,
      income: :income_proof_resubmission
    }.freeze

    Delivery = Struct.new(:secure_request_form, :raw_token, :candidate, :proof_review)

    attr_reader :application, :actor, :proof_type, :recipient_ids, :channel_overrides, :resend_of, :public_recovery,
                :deliver_request

    # rubocop:disable Metrics/ParameterLists
    def initialize(application:, actor:, proof_type:, recipient_ids: nil, channel_overrides: {}, resend_of: nil,
                   public_recovery: false, deliver_request: true)
      super()
      @application = application
      @actor = actor
      @proof_type = proof_type.to_sym
      @recipient_ids = recipient_ids
      @channel_overrides = channel_overrides
      @resend_of = resend_of
      @public_recovery = public_recovery
      @deliver_request = deliver_request
    end
    # rubocop:enable Metrics/ParameterLists

    def call
      return failure(message(:invalid_proof_type)) unless proof_kind
      return failure(message(:request_not_needed)) unless requestable_proof_state?

      deliveries, result = prepare_requests

      return result if result&.failure?

      if deliver_request
        delivery_result = deliver_requests(deliveries)
        return delivery_result if delivery_result.failure?
      end

      result
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("Proof resubmission request failed for application #{application.id}: #{e.message}")
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
        application.with_lock do
          result = validate_request_preconditions
          raise ActiveRecord::Rollback if result.failure?

          deliveries = create_requests_for(result.data)
          result = success(message(:request_created), result_data_for(deliveries))
        end
      end

      [deliveries, result]
    end

    def validate_request_preconditions
      repair_result = repair_managing_guardian_if_possible
      return repair_result unless repair_result.success?

      resolve_recipients
    end

    def proof_kind
      PROOF_KIND_BY_TYPE[proof_type]
    end

    def latest_rejection_review
      @latest_rejection_review ||= begin
        reviews = application.proof_reviews
        reviews.where(proof_type: proof_type, status: :rejected)
               .order(updated_at: :desc, created_at: :desc)
               .first
      end
    end

    def requestable_proof_state?
      return false if current_proof_status == 'approved'
      return latest_rejection_review.present? if current_proof_status == 'rejected'
      return false if current_proof_attachment.attached?

      current_proof_status == 'not_reviewed'
    end

    def current_proof_attachment
      application.public_send("#{proof_type}_proof")
    end

    def current_proof_status
      application.public_send("#{proof_type}_proof_status")
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
      # Despite the class name, this resolver owns the shared constituent/guardian
      # contact-path rules used by provider-info and proof secure forms.
      Applications::ProviderInfoRecipientResolver.new(
        application: application,
        recipient_ids: recipient_ids,
        channel_overrides: channel_overrides
      )
    end

    def resolver_for_resend
      Applications::ProviderInfoRecipientResolver.new(
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
        open_requests_for(candidate.recipient.id)
          .find_each { |request_form| request_form.revoke!(actor: actor, reason: :replacement_request) }
        create_delivery(candidate, request_batch_id)
      end
    end

    def ensure_cooldown_allows!(candidate)
      latest_request = SecureRequestForm
                       .public_send("#{proof_type}_proof")
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

    def open_requests_for(recipient_id)
      SecureRequestForm.public_send("open_#{proof_type}_proof_for_recipient",
                                    application_id: application.id,
                                    recipient_id: recipient_id)
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
      Delivery.new(
        secure_request_form: secure_request_form,
        raw_token: raw_token,
        candidate: candidate,
        proof_review: latest_rejection_review
      )
    end

    def secure_request_form_attributes(candidate, request_batch_id, raw_token)
      {
        application: application,
        kind: proof_kind,
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
        type: 'proof_resubmission_requested',
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
          proof_type: proof_type.to_s,
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
        :email
      end || :email
    end

    def deliver_requests(deliveries)
      delivery_failures = []

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
      end

      return failure(message(:delivery_failed), delivery_failure_data(delivery_failures, deliveries)) if delivery_failures.any?

      success
    end

    def deliver_email(delivery)
      # deliver_now is intentional: the email body contains the raw bearer URL,
      # which must not be serialized into Active Job arguments via deliver_later.
      proof_request_mail(
        delivery,
        secure_upload_url: secure_url_for(delivery.raw_token)
      ).deliver_now
    end

    def deliver_letter(delivery)
      proof_request_mail(delivery, secure_upload_url: nil).deliver_now
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
        Rails.logger.error("Proof resubmission delivery failed: #{context.inspect}")
      end
    end

    def reportable_delivery_error(error)
      StandardError.new(sanitize_secure_error_message(error.message)).tap do |reportable_error|
        reportable_error.set_backtrace(Array(error.backtrace).map { |line| sanitize_secure_error_message(line) })
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
        recipient_channels: forms.map(&:recipient_channel),
        proof_type: proof_type.to_s
      }
    end

    def result_data_for(deliveries)
      forms = Array(deliveries)
      data = { secure_request_forms: forms.map(&:secure_request_form) }

      data[:secure_upload_url] = secure_url_for(forms.first.raw_token) if should_return_public_url?(forms)

      data
    end

    def should_return_public_url?(deliveries)
      forms = Array(deliveries)
      forms.one? && (public_recovery || !deliver_request)
    end

    def secure_url_for(raw_token)
      options = Rails.application.config.action_mailer.default_url_options || {}
      host = options[:host]
      protocol = options[:protocol] || (Rails.env.production? ? 'https' : 'http')

      if Rails.env.production?
        raise ArgumentError, 'Secure proof form host is not configured' if host.blank? || host == 'example.com'
        raise ArgumentError, 'Secure proof form URLs must use HTTPS in production' unless protocol == 'https'
      end

      Rails.application.routes.url_helpers.secure_proof_form_url(
        token: raw_token,
        host: host,
        port: options[:port],
        protocol: protocol
      )
    end

    def sms_message(secure_url, secure_request_form)
      locale = secure_form_locale_for(secure_request_form.recipient)

      I18n.t(
        'secure_proof_forms.sms.message',
        locale: locale,
        secure_url: secure_url,
        proof_type: I18n.t("secure_proof_forms.proof_types.#{proof_type}", locale: locale),
        hours: link_expiration_hours
      )
    end

    def link_expiration_hours
      Policy.get('secure_form_link_expiration_hours') || 48
    end

    def resend_cooldown_hours
      Policy.get('secure_form_resend_cooldown_hours') || 1
    end

    def proof_request_mail(delivery, secure_upload_url:)
      if delivery.proof_review.present?
        ApplicationNotificationsMailer.proof_rejected(
          application,
          delivery.proof_review,
          secure_upload_url: secure_upload_url,
          recipient: delivery.secure_request_form.recipient
        )
      else
        ApplicationNotificationsMailer.proof_requested(
          application,
          proof_type,
          secure_upload_url: secure_upload_url,
          recipient: delivery.secure_request_form.recipient
        )
      end
    end

    def message(key, user: actor, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(user))
    end

    class CooldownActive < StandardError; end
  end
end
