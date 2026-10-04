# frozen_string_literal: true

module Applications
  # Records audit events for applications managed by guardians.
  class EventService < BaseService
    attr_reader :application, :user

    def initialize(application, user: nil)
      super()
      @application = application
      @user = user || application.user
    end

    # Records an update only when the application, dependent, or managing guardian has unsaved changes.
    # @param dependent [User, nil] The dependent, or nil to use application.user
    # @param relationship_type [String, nil] The relationship type, or nil to look it up
    # @return [Event, nil] The event, or nil if no changes exist or audit deduplication suppresses it
    def log_dependent_application_update(dependent: nil, relationship_type: nil)
      dependent ||= application.user

      relevant_changes = application.changed? || dependent.changed? || application.managing_guardian&.changed?

      return nil unless relevant_changes

      relationship_type ||= GuardianRelationship.find_by(
        guardian_id: application.managing_guardian_id,
        dependent_id: dependent.id
      )&.relationship_type

      AuditEventService.log(
        actor: user,
        action: 'application_for_dependent_updated',
        auditable: application,
        metadata: {
          application_id: application.id,
          dependent_id: dependent.id,
          managing_guardian_id: application.managing_guardian_id,
          guardian_relationship: relationship_type,
          timestamp: Time.current.iso8601
        }
      )
    end

    # Records a submission for a dependent.
    # @param dependent [User, nil] The dependent, or nil to use application.user
    # @param relationship_type [String, nil] The relationship type, or nil to look it up
    # @return [Event, nil] The event, or nil if audit deduplication suppresses it
    def log_dependent_application_submission(dependent: nil, relationship_type: nil)
      dependent ||= application.user

      relationship_type ||= GuardianRelationship.find_by(
        guardian_id: application.managing_guardian_id,
        dependent_id: dependent.id
      )&.relationship_type

      AuditEventService.log(
        actor: user,
        action: 'application_for_dependent_submitted',
        auditable: application,
        metadata: {
          application_id: application.id,
          dependent_id: dependent.id,
          managing_guardian_id: application.managing_guardian_id,
          guardian_relationship: relationship_type,
          timestamp: Time.current.iso8601
        }
      )
    end

    # Shares the contract of log_dependent_application_submission.
    # @param dependent [User, nil] The dependent, or nil to use application.user
    # @param relationship_type [String, nil] The relationship type, or nil to look it up
    # @return [Event, nil] The event, or nil if audit deduplication suppresses it
    def log_submission_for_dependent(dependent: nil, relationship_type: nil)
      log_dependent_application_submission(dependent: dependent, relationship_type: relationship_type)
    end
  end
end
