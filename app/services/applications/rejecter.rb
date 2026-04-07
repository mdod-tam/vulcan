# frozen_string_literal: true

module Applications
  # Service object to handle the application rejection process
  class Rejecter < BaseService
    attr_reader :application, :actor

    # Initializes the service
    # @param application [Application] The application to reject
    # @param by [User] The user performing the action
    def initialize(application, by:)
      super() # Initialize BaseService errors array
      @application = application
      @actor = by
    end

    # Executes the rejection process
    # @return [Boolean] True if successful, false otherwise
    def call
      ApplicationRecord.transaction do
        application.transition_status!(
          :rejected,
          actor: actor,
          metadata: { trigger: 'admin_rejection' }
        )
        # NOTE: The original model method didn't have event/notification for rejection.
        # If needed, they would be added here.
        true # Indicate success
      end
    rescue StandardError => e
      log_error(e, context: { application_id: application.id, actor_id: actor.id })
      # The add_error is called within log_error, which returns false
    end
  end
end
