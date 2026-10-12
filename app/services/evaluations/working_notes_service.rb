# frozen_string_literal: true

module Evaluations
  class WorkingNotesService < BaseService
    def initialize(evaluation, actor, params)
      super()
      @evaluation = evaluation
      @actor = actor
      @params = params
    end

    def call
      @evaluation.application.with_lock do
        @evaluation.with_lock do
          validate_access!
          @evaluation.update!(working_notes: @params[:working_notes].presence)
          record_change! if @evaluation.saved_change_to_working_notes?
        end
      end

      success('Working notes saved.', { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      failure(e.message)
    end

    private

    def validate_access!
      raise ArgumentError, 'Only the assigned evaluator can update this evaluation.' unless @evaluation.evaluator_id == @actor&.id
      raise ArgumentError, 'Working notes are read-only after report submission.' unless @evaluation.working_notes_editable?
    end

    def record_change!
      AuditEventService.log(
        action: 'evaluation_working_notes_updated', actor: @actor, auditable: @evaluation,
        metadata: { operation_id: SecureRandom.uuid, evaluation_id: @evaluation.id,
                    application_id: @evaluation.application_id, cleared: @evaluation.working_notes.blank? }
      )
    end
  end
end
