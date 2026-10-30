# frozen_string_literal: true

module Applications
  # Shared by the training and evaluation assignment writers. Users lock before the application, in ascending id
  # order, so a concurrent capability change and an assignment can never wait on each other.
  class PractitionerAssignment < BaseService
    # Ends a refused assignment with the reason the administrator sees. The transaction rolls back.
    class Rejected < StandardError; end

    attr_reader :application, :actor

    # @param application [Application] The application whose practitioner assignment changes
    # @param actor [User] The administrator making the change
    def initialize(application, actor:)
      super()
      @application = application
      @actor = actor
    end

    private

    # Runs a writer in one transaction. A refusal or an invalid record rolls it back and comes back as a failure
    # whose message is the reason; notification_outcomes lists the notices queued for delivery after commit.
    def in_transaction(&)
      @notification_outcomes = []
      ApplicationRecord.transaction(&)
      success(nil, notification_outcomes: @notification_outcomes)
    rescue Rejected => e
      failure(e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    end

    # Locks the assignee, the acting administrator and any current assignees, then returns the assignee and actor
    # rows plus the locked ids. A missing or unsaved participant comes back nil and fails the caller's eligibility check.
    def lock_participants(assignee, current_assignee_ids = [])
      ids = User.where(id: [assignee&.id, actor&.id, *current_assignee_ids].compact.uniq).pluck(:id)
      locked = ids.empty? ? {} : User.lock_for_merge_integrity!(ids)
      [locked[assignee&.id], locked[actor&.id], locked.keys]
    end

    def actor_eligible?(locked_actor)
      locked_actor&.admin? && locked_actor.public_login_active?
    end

    # A String is the message. A Symbol names an application error under activerecord.errors.models.application.
    def reject!(reason)
      raise Rejected, reason.is_a?(Symbol) ? application.errors.generate_message(:base, reason) : reason
    end
  end
end
