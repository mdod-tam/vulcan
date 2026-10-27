# frozen_string_literal: true

module Evaluations
  class SupplementalNotesService < BaseService
    def initialize(evaluation, actor, params)
      super()
      @evaluation = evaluation
      @actor = actor
      @params = params
    end

    def call
      @evaluation.with_actor_and_application_lock(@actor) do
        raise ArgumentError, 'Supplemental notes can only be added after the report is submitted.' unless @evaluation.status_completed?

        @evaluation.update!(post_completion_notes: @params[:post_completion_notes])
      end

      success('Evaluation updated successfully.', { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      failure(e.message)
    end
  end
end
