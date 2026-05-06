# frozen_string_literal: true

module TrainingSessions
  class AuditLogBuilder < BaseService
    def initialize(training_session)
      super()
      @training_session = training_session
    end

    def build
      return [] if @training_session.blank?

      events = auditable_events.to_a + metadata_events.to_a
      events.uniq(&:id).sort_by(&:created_at).reverse
    end

    private

    def auditable_events
      Event.includes(:user).where(auditable: @training_session)
    end

    def metadata_events
      Event.includes(:user).where("metadata->>'training_session_id' = ?", @training_session.id.to_s)
    end
  end
end
