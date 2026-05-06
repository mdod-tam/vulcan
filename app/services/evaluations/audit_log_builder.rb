# frozen_string_literal: true

module Evaluations
  class AuditLogBuilder < BaseService
    APPLICATION_LEVEL_ACTIONS = %w[
      evaluator_assigned
      equipment_bids_sent
      equipment_po_sent
    ].freeze

    def initialize(evaluation)
      super()
      @evaluation = evaluation
    end

    def build
      return [] if @evaluation.blank?

      events = evaluation_events + scoped_application_events
      events.uniq(&:id).sort_by(&:created_at).reverse
    end

    private

    def evaluation_events
      (auditable_events.to_a + metadata_events.to_a).uniq(&:id)
    end

    def auditable_events
      Event.includes(:user).where(auditable: @evaluation)
    end

    def metadata_events
      Event.includes(:user).where("metadata->>'evaluation_id' = ?", @evaluation.id.to_s)
    end

    def scoped_application_events
      return [] if @evaluation.application.blank?

      Event.includes(:user)
           .where(auditable: @evaluation.application, action: APPLICATION_LEVEL_ACTIONS)
           .to_a
    end
  end
end
