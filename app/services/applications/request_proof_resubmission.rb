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

    attr_reader :application, :actor, :proof_type, :recipient_ids, :channel_overrides, :resend_of, :public_recovery

    # rubocop:disable-next Metrics/ParameterLists
    def initialize(application:, actor:, proof_type:, recipient_ids: nil, channel_overrides: {}, resend_of: nil,
                   public_recovery: false)
      super()
      @application = application
      @actor = actor
      @proof_type = proof_type.to_sym
      @recipient_ids = recipient_ids
      @channel_overrides = channel_overrides
      @resend_of = resend_of
      @public_recovery = public_recovery
    end

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
      with_recipient_issuance_errors do
        Letters::Delivery.reconcile_pending!(scope: PrintQueueItem.unreleased.where(application_id: application.id))
        return failure(message(:invalid_proof_type)) unless proof_kind
        return failure(message(:request_not_needed)) unless requestable_proof_state?

        deliveries = prepare_requests do
          # Repeat the preliminary proof-state check under the issuance lock.
          raise SecureRequestIssuance::Refused, :request_not_needed unless requestable_proof_state?
        end
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
        kind: proof_kind,
        form_scope: "#{proof_type}_proof"
      )
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

    def create_delivery(candidate, request_batch_id)
      issued = issuance.replace_request!(
        candidate: candidate, request_batch_id: request_batch_id, notification_type: 'proof_resubmission_requested',
        tracking_metadata: {
          proof_type: proof_type.to_s,
          proof_request_display_mode: proof_request_display_mode,
          rejection_reason: proof_request_rejection_reason
        }.compact
      )
      Delivery.new(
        secure_request_form: issued.secure_request_form,
        raw_token: issued.raw_token,
        candidate: candidate,
        proof_review: proof_request_rejected? ? latest_rejection_review : nil,
        context: authorization_for(candidate).last,
        notification_id: issued.notification_id
      )
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

    def sms_action = 'SmsService#proof_resubmission'

    def deliver_letter(delivery)
      EmailDelivery.deliver_now!(proof_request_mail(delivery, secure_upload_url: nil), context: delivery_context_for(delivery))
    end

    def delivery_failure_details(forms)
      super.merge(proof_type: proof_type.to_s)
    end

    def public_recovery_message = message(:resent, user: resend_of&.recipient || actor)

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
  end
end
