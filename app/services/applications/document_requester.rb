# frozen_string_literal: true

module Applications
  # Service object to handle requesting documents for an application
  class DocumentRequester < BaseService
    attr_reader :application, :actor

    # Initializes the service
    # @param application [Application] The application needing documents
    # @param by [User] The user performing the action
    def initialize(application, by:)
      super() # Initialize BaseService errors array
      @application = application
      @actor = by
    end

    # Executes the document request process
    # @return [Boolean] True if successful, false otherwise
    def call
      ApplicationRecord.transaction do
        application.escalate_to_dcf!(actor: actor, trigger: :document_request)

        AuditEventService.log(
          action: 'documents_requested',
          actor: actor,
          auditable: application
        )

        NotificationService.create_and_deliver!(
          type: 'documents_requested',
          recipient: application.user,
          actor: actor,
          notifiable: application,
          channel: :email
        )
      end
      true
    rescue StandardError => e
      log_error(e, context: { application_id: application.id, actor_id: actor.id })
    end
  end
end
