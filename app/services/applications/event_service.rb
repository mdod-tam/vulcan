# frozen_string_literal: true

module Applications
  # Service to handle application event creation and tracking
  # This service ensures events are created correctly and consistently
  class EventService < BaseService
    attr_reader :application, :user

    def initialize(application, user: nil)
      super()
      @application = application
      @user = user || application.user
    end

    # Create an event for updating an application submitted for a dependent by a guardian
    # This checks if relevant attributes related to the dependent or guardian changed
    # @param dependent [User] The dependent user (optional, defaults to application.user)
    # @param relationship_type [String] The relationship type (optional, will be looked up if not provided)
    # @return [Event] The created event record, or nil if event should be skipped
    def log_dependent_application_update(dependent: nil, relationship_type: nil)
      dependent ||= application.user

      # Check if we should skip event creation because only irrelevant attributes changed
      # We log if the application itself changed, or if the applicant (dependent) or managing guardian changed
      relevant_changes = application.changed? || dependent.changed? || application.managing_guardian&.changed?

      return nil unless relevant_changes

      # If relationship_type wasn't provided, try to look it up
      relationship_type ||= GuardianRelationship.find_by(
        guardian_id: application.managing_guardian_id,
        dependent_id: dependent.id
      )&.relationship_type

      AuditEventService.log(
        actor: user, # The user performing the action (likely the guardian)
        action: 'application_for_dependent_updated',
        auditable: application,
        metadata: {
          application_id: application.id,
          dependent_id: dependent.id,
          managing_guardian_id: application.managing_guardian_id,
          guardian_relationship: relationship_type, # Include for context if found
          timestamp: Time.current.iso8601
        }
      )
    end

    # Create an event for submitting an application for a dependent by a guardian
    # @param dependent [User] The dependent user (optional, defaults to application.user)
    # @param relationship_type [String] The relationship type (optional, will be looked up if not provided)
    # @return [Event] The created event record
    def log_dependent_application_submission(dependent: nil, relationship_type: nil)
      dependent ||= application.user

      # If relationship_type wasn't provided, try to look it up
      relationship_type ||= GuardianRelationship.find_by(
        guardian_id: application.managing_guardian_id,
        dependent_id: dependent.id
      )&.relationship_type

      AuditEventService.log(
        actor: user, # The user performing the action (likely the guardian)
        action: 'application_for_dependent_submitted',
        auditable: application,
        metadata: {
          application_id: application.id,
          dependent_id: dependent.id,
          managing_guardian_id: application.managing_guardian_id,
          guardian_relationship: relationship_type, # Include for context if found
          timestamp: Time.current.iso8601
        }
      )
    end

    # Another name for log_dependent_application_submission for backward compatibility
    # @param dependent [User] The dependent user
    # @param relationship_type [String] The relationship type
    # @return [Event] The created event record
    def log_submission_for_dependent(dependent: nil, relationship_type: nil)
      log_dependent_application_submission(dependent: dependent, relationship_type: relationship_type)
    end

    # The only_nested_attributes_changed? method was removed as it is no longer needed
    # with the updated event logging logic.
  end
end
