# frozen_string_literal: true

module Applications
  class RequestProofResubmission < BaseService
    include SecureFormLocaleResolver
    include SecureRequestDeliveryPolicy

    MESSAGE_SCOPE = 'applications.proof_resubmission.messages'
    PROOF_KIND_BY_TYPE = {
      id: :id_proof_resubmission,
      residency: :residency_proof_resubmission,
      income: :income_proof_resubmission
    }.freeze

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

    def self.delivery_confirmed_for_review?(proof_review)
      proof_type = proof_review.proof_type.to_sym
      return false unless PROOF_KIND_BY_TYPE.key?(proof_type)

      # Failed deliveries retain revoked rows for audit. They must not suppress admin warnings.
      SecureRequestForm.public_send("#{proof_type}_proof")
                       .active
                       .where(application_id: proof_review.application_id)
                       .exists?(created_at: proof_review.created_at..)
    end

    def call
      Letters::Delivery.reconcile_pending!(scope: PrintQueueItem.unreleased.where(application_id: application.id))
      return failure(message(:invalid_proof_type)) unless proof_kind
      return failure(message(:request_not_needed)) unless requestable_proof_state?

      deliveries, result = prepare_requests

      return result if result&.failure?

      if deliver_request
        delivery_result = deliver_requests(deliveries)
        return delivery_result if delivery_result.failure?
      end

      return delivery_denial_result(deliveries) if denied_candidates.any?

      result
    rescue ActiveRecord::RecordNotUnique,
           ActiveRecord::RecordInvalid,
           ActiveRecord::RecordNotFound,
           Applications::SecureRequestIssuanceIntegrity::ParticipantSetUnstable => e
      Rails.logger.warn("Proof resubmission request failed for application #{application.id}: #{e.message}")
      failure(message(:request_conflict))
    rescue SecureRequestIssuance::Refused => e
      failure(message(e.reason))
    rescue SecureRequestIssuance::CooldownActive => e
      return success(message(:resent, user: resend_of&.recipient || actor)) if public_recovery

      failure(message(:cooldown_active, minutes: e.minutes))
    end

    private

    def prepare_requests
      deliveries = nil
      result = nil

      issuance.with_locked_context do |context|
        install_locked_context!(context)
        # Repeat #call's preliminary state check under the issuance lock.
        unless requestable_proof_state?
          result = failure(message(:request_not_needed))
          raise ActiveRecord::Rollback
        end

        candidates = issuance.resolve_recipients!(recipient_ids: recipient_ids, channel_overrides: channel_overrides)
        deliveries = create_requests_for(candidates)
        result = if deliveries.empty? && denied_candidates.any?
                   delivery_denial_result(deliveries)
                 else
                   success(message(:request_created), result_data_for(deliveries))
                 end
      end

      [deliveries, result]
    end

    def issuance
      @issuance ||= SecureRequestIssuance.new(
        application: application,
        actor: actor,
        resend_of: resend_of,
        kind: proof_kind,
        form_scope: "#{proof_type}_proof"
      )
    end

    def install_locked_context!(context)
      @application = context.application
      @actor = context.actor
      @resend_of = context.resend_of
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
      application.proof_requestable_via_secure_form?(proof_type)
    end

    def current_proof_status
      application.public_send("#{proof_type}_proof_status")
    end

    # Refuse each denied channel before token creation; eligible recipients still proceed.
    def create_requests_for(candidates)
      request_batch_id = SecureRandom.uuid
      candidates.filter_map do |candidate|
        if delivery_denied_for?(candidate)
          denied_candidates << candidate
          next
        end

        create_delivery(candidate, request_batch_id)
      end
    end

    def create_delivery(candidate, request_batch_id)
      issued = issuance.replace_request!(candidate: candidate, request_batch_id: request_batch_id)
      secure_request_form = issued.secure_request_form
      notification = create_tracking_notification(secure_request_form)
      raise SecureRequestIssuance::Refused, :request_conflict unless notification

      Delivery.new(
        secure_request_form: secure_request_form,
        raw_token: issued.raw_token,
        candidate: candidate,
        proof_review: proof_request_rejected? ? latest_rejection_review : nil,
        context: authorization_for(candidate).last,
        notification_id: notification.id
      )
    end

    def create_tracking_notification(secure_request_form)
      NotificationService.create_and_deliver!(
        type: 'proof_resubmission_requested',
        recipient: secure_request_form.recipient,
        actor: actor,
        notifiable: application,
        metadata: tracking_notification_metadata(secure_request_form),
        channel: notification_channel_for(secure_request_form),
        audit: true,
        deliver: false
      )
    end

    def tracking_notification_metadata(secure_request_form)
      {
        secure_request_form_id: secure_request_form.id,
        application_id: application.id,
        recipient_id: secure_request_form.recipient_id,
        recipient_role: secure_request_form.recipient_role,
        recipient_channel: secure_request_form.recipient_channel,
        requested_recipient_channel: secure_request_form.recipient_channel,
        delivery_owner_id: secure_request_form.delivery_owner_id,
        delivery_source: secure_request_form.delivery_source,
        request_batch_id: secure_request_form.request_batch_id,
        proof_type: proof_type.to_s,
        proof_request_display_mode: proof_request_display_mode,
        rejection_reason: proof_request_rejection_reason,
        expires_at: secure_request_form.expires_at.iso8601
      }.compact
    end

    def proof_request_display_mode
      proof_request_rejected? ? 'rejected' : 'requested'
    end

    def proof_request_rejected?
      current_proof_status == 'rejected'
    end

    def proof_request_rejection_reason
      return unless proof_request_rejected?

      latest_rejection_review&.rejection_reason
    end

    def deliver_email(delivery)
      # deliver_now keeps the raw bearer URL out of Active Job arguments.
      EmailDelivery.deliver_now!(
        proof_request_mail(
          delivery,
          secure_upload_url: secure_url_for(delivery.raw_token)
        ),
        context: delivery_context_for(delivery)
      )
    end

    def delivery_mail_action
      proof_request_rejected? ? 'ApplicationNotificationsMailer#proof_rejected' : 'ApplicationNotificationsMailer#proof_requested'
    end

    def delivery_requested? = deliver_request
    def sms_action = 'SmsService#proof_resubmission'

    def deliver_letter(delivery)
      EmailDelivery.deliver_now!(proof_request_mail(delivery, secure_upload_url: nil), context: delivery_context_for(delivery))
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

    def delivery_failure_details(forms)
      super.merge(proof_type: proof_type.to_s)
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
      SecureFormPolicy.public_url(:secure_proof_form_url, raw_token)
    end

    def sms_message(secure_url, secure_request_form)
      locale = secure_request_form.delivery_locale

      I18n.t(
        'secure_proof_forms.sms.message',
        locale: locale,
        secure_url: secure_url,
        proof_type: I18n.t("secure_proof_forms.proof_types.#{proof_type}", locale: locale),
        hours: SecureFormPolicy.link_expiration_hours
      )
    end

    # The mailer must use the form's channel and encrypted contact snapshot, not the recipient's preferences.
    # letter_recipient supplies the resolver's address owner for print delivery.
    def proof_request_mail(delivery, secure_upload_url:)
      if delivery.proof_review.present?
        ApplicationNotificationsMailer.proof_rejected(
          application,
          delivery.proof_review,
          secure_upload_url: secure_upload_url,
          recipient: delivery.secure_request_form.recipient,
          secure_request_form: delivery.secure_request_form,
          letter_recipient: delivery.candidate.address_owner
        )
      else
        ApplicationNotificationsMailer.proof_requested(
          application,
          proof_type,
          secure_upload_url: secure_upload_url,
          recipient: delivery.secure_request_form.recipient,
          secure_request_form: delivery.secure_request_form,
          letter_recipient: delivery.candidate.address_owner
        )
      end
    end

    def message(key, user: actor, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(user))
    end
  end
end
