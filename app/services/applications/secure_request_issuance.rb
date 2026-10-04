# frozen_string_literal: true

module Applications
  # Shared issuance mechanics for applicant/guardian proof and provider-info links.
  # The caller keeps workflow validation and delivery inside/outside the lock, respectively.
  class SecureRequestIssuance
    IssuedRequest = Data.define(:secure_request_form, :raw_token)

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
    def replace_request!(candidate:, request_batch_id:)
      requests = open_requests_for(candidate.recipient.id)
      ensure_cooldown_allows!(requests)
      requests.order(:id).lock.each { |form| form.revoke!(actor: @context.actor, reason: :replacement_request) }
      create_request!(candidate, request_batch_id)
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

    def ensure_cooldown_allows!(requests)
      latest_request = requests.order(sent_at: :desc).first
      return if latest_request.blank?

      cooldown_until = latest_request.sent_at + SecureFormPolicy.resend_cooldown_hours.hours
      return if cooldown_until <= Time.current

      raise CooldownActive, ((cooldown_until - Time.current) / 60.0).ceil
    end

    def create_request!(candidate, request_batch_id)
      attempts = 0
      begin
        attempts += 1
        raw_token = SecureRequestForm.generate_public_token
        # A digest collision must roll back its savepoint before retrying on PostgreSQL.
        form = ApplicationRecord.transaction(requires_new: true) do
          SecureRequestForm.create!(request_attributes(candidate, request_batch_id, raw_token))
        end
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < 2

        raise
      end
      IssuedRequest.new(secure_request_form: form, raw_token: raw_token)
    end

    def request_attributes(candidate, request_batch_id, raw_token)
      {
        application: @context.application,
        kind: @kind,
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
        requested_by: @context.actor
      }
    end
  end
end
