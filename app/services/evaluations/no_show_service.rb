# frozen_string_literal: true

module Evaluations
  class NoShowService < BaseService
    def initialize(evaluation, actor, params)
      super()
      @evaluation = evaluation
      @actor = actor
      @params = params
    end

    def call
      @evaluation.with_actor_and_application_lock(@actor) do
        validate_transition!
        @evaluation.update!(
          status: :no_show,
          notes: no_show_notes
        )
        create_event!
      end

      success('Evaluation marked as no-show.', { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error marking evaluation as no-show: #{e.class.name}")
      failure(e.message)
    rescue ArgumentError => e
      Rails.logger.warn("Evaluations::NoShowService validation failed: #{e.class.name}")
      failure(e.message)
    end

    private

    def validate_transition!
      raise ArgumentError, 'Only the assigned evaluator can update this evaluation.' unless @evaluation.evaluator_id == @actor&.id
      raise ArgumentError, 'Only scheduled or confirmed evaluations can be marked as no-show.' unless @evaluation.status_scheduled? || @evaluation.status_confirmed?
      raise ArgumentError, 'evaluation_date is required before marking an evaluation as no-show' if @evaluation.evaluation_date.blank?
      raise ArgumentError, 'Evaluation can only be marked as no-show after its scheduled time.' if @evaluation.evaluation_date.future?
    end

    def no_show_notes
      @params[:notes].presence
    end

    def create_event!
      AuditEventService.log(
        action: 'evaluation_no_show',
        actor: @actor,
        auditable: @evaluation,
        metadata: {
          evaluation_id: @evaluation.id,
          application_id: @evaluation.application_id,
          evaluation_date: @evaluation.evaluation_date&.iso8601,
          no_show_notes: no_show_notes,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
