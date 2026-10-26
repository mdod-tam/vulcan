# frozen_string_literal: true

module Evaluations
  class CancelService < BaseService
    def initialize(evaluation, actor, params)
      super()
      @evaluation = evaluation
      @actor = actor
      @params = params
    end

    def call
      @evaluation.with_actor_and_application_lock(@actor) do
        validate_params!
        @evaluation.update!(
          status: :cancelled,
          notes: cancellation_reason
        )
        create_event!
      end

      success('Evaluation cancelled successfully.', { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error cancelling evaluation: #{e.class.name}")
      failure(e.message)
    rescue ArgumentError => e
      Rails.logger.warn("Evaluations::CancelService validation failed: #{e.class.name}")
      failure(e.message)
    end

    private

    def validate_params!
      raise ArgumentError, 'Only the assigned evaluator can update this evaluation.' unless @evaluation.evaluator_id == @actor&.id
      raise ArgumentError, 'Only requested, scheduled, or confirmed evaluations can be cancelled.' unless @evaluation.can_cancel?
      return if cancellation_reason.present?

      @evaluation.errors.add(:notes, 'must include a cancellation reason')
      raise ArgumentError, 'cancellation reason is required'
    end

    def cancellation_reason
      @params[:notes].presence
    end

    def create_event!
      AuditEventService.log(
        action: 'evaluation_cancelled',
        actor: @actor,
        auditable: @evaluation,
        metadata: {
          evaluation_id: @evaluation.id,
          application_id: @evaluation.application_id,
          evaluation_date: @evaluation.evaluation_date&.iso8601,
          cancellation_reason: cancellation_reason,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
