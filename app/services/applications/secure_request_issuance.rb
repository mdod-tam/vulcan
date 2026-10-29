# frozen_string_literal: true

module Applications
  # Lock inventory, recipient resolution, and per-recipient replacement for applicant/guardian
  # proof and provider-info links. SecureFormReplacement owns cooldown, revocation, and token creation.
  # The caller keeps workflow validation and delivery inside/outside the lock, respectively.
  class SecureRequestIssuance
    IssuedRequest = Data.define(:secure_request_form, :raw_token, :notification_id)

    class Refused < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason.to_s)
      end
    end

    class CooldownActive < StandardError
      attr_reader :minutes

      def initialize(minutes)
        @minutes = minutes
        super('secure-request resend cooldown active')
      end
    end

    def initialize(application:, actor:, kind:, form_scope:, resend_of: nil)
      @integrity = SecureRequestIssuanceIntegrity.new(application: application, actor: actor, resend_of: resend_of)
      @kind = kind
      @form_scope = form_scope
    end

    def with_locked_context
      @integrity.with_locked_context do |context|
        @context = context
        raise Refused, :recipient_no_longer_eligible unless context.actor.admin? && context.actor.public_login_active?

        yield context
      end
    end

    def resolve_recipients!(recipient_ids:, channel_overrides:)
      repair_managing_guardian!
      candidates = recipient_resolver(recipient_ids, channel_overrides).resolve
      requested_count = Array(recipient_ids).compact_blank.size
      raise Refused, :unknown_recipient if recipient_ids.present? && @context.resend_of.blank? && candidates.size != requested_count

      raise Refused, candidates.find(&:failure_reason).failure_reason if candidates.any?(&:failure_reason)
      raise Refused, :no_recipient if candidates.blank?

      candidates.each { |candidate| candidate.recipient = @context.locked_users.fetch(candidate.recipient.id) }
      raise Refused, :recipient_no_longer_eligible unless candidates.all?(&:delivery_participants_eligible?)

      candidates
    end

    # The caller's issuance transaction also owns replacement revocations and tracking.
    def replace_request!(candidate:, request_batch_id:, notification_type:, tracking_metadata: {})
      issued = SecureFormReplacement.replace!(
        open: open_requests_for(candidate.recipient.id),
        actor: @context.actor,
        attributes: request_attributes(candidate),
        request_batch_id: request_batch_id
      )
      form = issued.secure_request_form
      notification = NotificationService.create_and_deliver!(
        type: notification_type,
        recipient: form.recipient,
        actor: @context.actor,
        notifiable: @context.application,
        metadata: tracking_notification_metadata(form).merge(tracking_metadata),
        channel: form.recipient_channel.to_sym,
        audit: true,
        deliver: false
      )
      raise Refused, :request_conflict unless notification

      IssuedRequest.new(secure_request_form: form, raw_token: issued.raw_token, notification_id: notification.id)
    end

    private

    def recipient_resolver(recipient_ids, channel_overrides)
      resend = @context.resend_of
      SecureRequestRecipientResolver.new(
        application: @context.application,
        recipient_ids: resend.present? ? [resend.recipient_id] : recipient_ids,
        channel_overrides: resend.present? ? { resend.recipient_id => resend.recipient_channel } : channel_overrides,
        known_recipients: @context.known_recipients,
        guardian_relationships: @context.guardian_relationships
      )
    end

    def repair_managing_guardian!
      application = @context.application
      relationships = @context.guardian_relationships
      return if application.managing_guardian_id.present? || relationships.empty?

      raise Refused, :needs_managing_guardian unless relationships.one?

      application.update!(managing_guardian_id: relationships.first.guardian_id)
    end

    def open_requests_for(recipient_id)
      SecureRequestForm.public_send("open_#{@form_scope}_for_recipient",
                                    application_id: @context.application.id, recipient_id: recipient_id)
    end

    def tracking_notification_metadata(form)
      {
        secure_request_form_id: form.id,
        application_id: form.application_id,
        recipient_id: form.recipient_id,
        recipient_role: form.recipient_role,
        recipient_channel: form.recipient_channel,
        requested_recipient_channel: form.recipient_channel,
        delivery_owner_id: form.delivery_owner_id,
        delivery_source: form.delivery_source,
        request_batch_id: form.request_batch_id,
        expires_at: form.expires_at.iso8601
      }.compact
    end

    def request_attributes(candidate)
      {
        application: @context.application,
        kind: @kind,
        recipient: candidate.recipient,
        recipient_email: candidate.email,
        recipient_phone: candidate.phone,
        recipient_channel: candidate.channel,
        recipient_role: candidate.recipient_role,
        recipient_relationship_type: candidate.recipient_relationship_type,
        delivery_owner: candidate.delivery_owner,
        delivery_source: candidate.delivery_source&.to_s
      }
    end
  end
end
