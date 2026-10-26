# frozen_string_literal: true

module Applications
  # Moves an application to rejected.
  class Rejecter < BaseService
    attr_reader :application, :actor

    # @param application [Application] The application to reject
    # @param by [User] The user performing the action
    def initialize(application, by:)
      super()
      @application = application
      @actor = by
    end

    # @return [Boolean] True if successful, false otherwise
    def call
      ApplicationRecord.transaction do
        application.transition_status!(
          :rejected,
          actor: actor,
          metadata: { trigger: 'admin_rejection' }
        )
        true
      end
    rescue StandardError => e
      log_error(e, context: { application_id: application.id, actor_id: actor.id })
      # log_error records the error and returns false.
    end
  end
end
