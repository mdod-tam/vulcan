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
      @evaluation.with_actor_and_application_lock(@actor) do
        validate_access!
        @evaluation.update!(working_notes: @params[:working_notes].presence)
        record_change! if @evaluation.saved_change_to_working_notes?
      end

      success('Working notes saved.', { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      failure(e.message)
    end

    private

    def validate_access!
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
