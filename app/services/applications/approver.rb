# frozen_string_literal: true

module Applications
  # Service object to handle the application approval process
  class Approver < BaseService
    attr_reader :application, :actor

    # Initializes the service
    # @param application [Application] The application to approve
    # @param by [User] The user performing the action
    def initialize(application, by:)
      super() # Initialize BaseService errors array
      @application = application
      @actor = by
    end

    # Executes the approval process
    # @return [Boolean] True if successful, false otherwise
    def call
      ApplicationRecord.transaction do
        application.update!(status: :approved)

        # Create event for approval
        Event.create!(
          user: actor,
          action: 'application_approved',
          metadata: {
            application_id: application.id,
            timestamp: Time.current.iso8601
          }
        )

        # Create initial voucher if applicable
        if FeatureFlag.enabled?(:vouchers_enabled) && application.can_create_voucher?
          application.create_initial_voucher 
        end

        true # Indicate success
      end
    rescue StandardError => e
      log_error(e, context: { application_id: application.id, actor_id: actor.id })
      # The add_error is called within log_error, which returns false
    end
  end
end
