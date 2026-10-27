# frozen_string_literal: true

module Applications
  # Moves an application to approved and records the approval event.
  class Approver < BaseService
    attr_reader :application, :actor

    # @param application [Application] The application to approve
    # @param by [User] The user performing the action
    def initialize(application, by:)
      super()
      @application = application
      @actor = by
    end

    # @return [Boolean] True if successful, false otherwise
    def call
      ApplicationRecord.transaction do
        application.transition_status!(:approved, actor: actor)

        AuditEventService.log(
          actor: actor,
          action: 'application_approved',
          auditable: application,
          metadata: {
            application_id: application.id,
            timestamp: Time.current.iso8601
          }
        )

        true
      end
    rescue StandardError => e
      log_error(e, context: { application_id: application.id, actor_id: actor.id })
      # log_error records the error and returns false.
    end
  end
end
