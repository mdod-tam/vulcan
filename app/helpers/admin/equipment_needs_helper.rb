# frozen_string_literal: true

module Admin
  module EquipmentNeedsHelper
    def equipment_source_report(application)
      source = application.equipment_needs.filter_map(&:source_evaluation).first
      return source if source

      initialization = application.events.where(action: 'equipment_needs_initialized').order(:created_at, :id).first
      return application.evaluations.find_by(id: initialization.metadata['source_evaluation_id']) if initialization

      application.evaluations.completed_sessions.by_report_submission.first
    end
  end
end
