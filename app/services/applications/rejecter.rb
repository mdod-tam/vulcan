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

    # @return [Boolean] True if successful; raises if the operation fails
    def call
      ApplicationRecord.transaction do
        application.transition_status!(
          :rejected,
          actor: actor,
          metadata: { trigger: 'admin_rejection' }
        )
        true
      end
    end
  end
end
