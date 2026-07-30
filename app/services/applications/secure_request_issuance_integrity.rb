# frozen_string_literal: true

module Applications
  # Owns the lock inventory shared by secure-request issuance services.
  #
  # Every base User row is locked in ascending-id order before any Application,
  # GuardianRelationship, or SecureRequestForm row. If the exact locked application
  # reveals a recipient absent from the unlocked inventory snapshot, the savepoint is
  # rolled back and the whole acquisition is retried with the expanded User set.
  class SecureRequestIssuanceIntegrity
    MAX_LOCK_ATTEMPTS = 3

    Context = Data.define(
      :application,
      :actor,
      :resend_of,
      :locked_users,
      :guardian_relationships,
      :known_recipients
    )

    class ParticipantSetChanged < StandardError
      attr_reader :participant_ids

      def initialize(participant_ids)
        @participant_ids = participant_ids
        super('secure-request issuance participant set changed')
      end
    end

    class ParticipantSetUnstable < StandardError; end

    def initialize(application:, actor:, resend_of: nil)
      @application_id = application.id
      @actor_id = actor&.id
      @resend_of_id = resend_of&.id
      @resend_recipient_id = resend_of&.recipient_id
    end

    def with_locked_context(&)
      participant_ids = initial_participant_ids
      attempts = 0

      begin
        attempts += 1
        ApplicationRecord.transaction(requires_new: true) do
          yield build_locked_context(participant_ids)
        end
      rescue ParticipantSetChanged => e
        raise ParticipantSetUnstable if attempts >= MAX_LOCK_ATTEMPTS

        participant_ids |= e.participant_ids
        retry
      end
    end

    private

    def initial_participant_ids
      user_id, managing_guardian_id = Application.where(id: @application_id).pick(:user_id, :managing_guardian_id)
      guardian_ids = GuardianRelationship.where(dependent_id: user_id).pluck(:guardian_id)

      compact_ids(@actor_id, @resend_recipient_id, user_id, managing_guardian_id, guardian_ids)
    end

    def build_locked_context(participant_ids)
      locked_users = User.lock_for_merge_integrity!(participant_ids)
      locked_application = Application.where(id: @application_id).order(:id).lock.first!
      relationships = GuardianRelationship
                      .where(dependent_id: locked_application.user_id)
                      .order(:id)
                      .lock
                      .to_a
      locked_resend = lock_resend_form

      exact_ids = compact_ids(
        @actor_id,
        locked_application.user_id,
        locked_application.managing_guardian_id,
        relationships.map(&:guardian_id),
        locked_resend&.recipient_id
      )
      missing_ids = exact_ids - locked_users.keys
      raise ParticipantSetChanged, missing_ids if missing_ids.any?

      hydrate_associations!(locked_application, relationships, locked_users)

      Context.new(
        application: locked_application,
        actor: locked_users.fetch(@actor_id),
        resend_of: locked_resend,
        locked_users: locked_users,
        guardian_relationships: relationships,
        known_recipients: known_recipients(locked_application, relationships, locked_users)
      )
    end

    def lock_resend_form
      return if @resend_of_id.blank?

      SecureRequestForm.where(id: @resend_of_id).order(:id).lock.first!
    end

    def hydrate_associations!(application, relationships, locked_users)
      application.association(:user).target = locked_users.fetch(application.user_id)
      application.association(:managing_guardian).target = locked_users.fetch(application.managing_guardian_id) if
        application.managing_guardian_id.present?

      relationships.each do |relationship|
        relationship.association(:guardian_user).target = locked_users.fetch(relationship.guardian_id)
      end
    end

    def known_recipients(application, relationships, locked_users)
      ids = compact_ids(
        application.user_id,
        application.managing_guardian_id,
        relationships.map(&:guardian_id)
      )
      ids.map { |id| locked_users.fetch(id) }
    end

    def compact_ids(*values)
      values.flatten.compact_blank.map(&:to_i).uniq
    end
  end
end
