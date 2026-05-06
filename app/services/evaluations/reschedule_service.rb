# frozen_string_literal: true

module Evaluations
  class RescheduleService < BaseService
    def initialize(evaluation, actor, params)
      super()
      @evaluation = evaluation
      @actor = actor
      @params = params
    end

    def call
      validate_params!

      old_evaluation_date = @evaluation.evaluation_date

      ActiveRecord::Base.transaction do
        reschedule_evaluation!
        create_event!(old_evaluation_date)
      end

      success('Evaluation rescheduled successfully.', { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error rescheduling evaluation: #{e.message}")
      failure(e.message)
    rescue ArgumentError => e
      log_validation_failure(e)
      failure(e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error rescheduling evaluation: #{e.message}")
      failure("An unexpected error occurred: #{e.message}")
    end

    private

    def validate_params!
      return unless @params[:evaluation_date].blank? || @params[:reschedule_reason].blank?

      raise ArgumentError, 'evaluation_date and reschedule_reason are required'
    end

    def reschedule_evaluation!
      @evaluation.update!(
        evaluation_date: @params[:evaluation_date],
        location: @params[:location],
        reschedule_reason: @params[:reschedule_reason],
        status: :scheduled
      )
    end

    def create_event!(old_evaluation_date)
      AuditEventService.log(
        action: 'evaluation_rescheduled',
        actor: @actor,
        auditable: @evaluation,
        metadata: {
          evaluation_id: @evaluation.id,
          application_id: @evaluation.application_id,
          old_evaluation_date: old_evaluation_date&.iso8601,
          evaluation_date: @evaluation.evaluation_date&.iso8601,
          reschedule_reason: @evaluation.reschedule_reason,
          location: @evaluation.location,
          timestamp: Time.current.iso8601
        }
      )
    end

    def log_validation_failure(error)
      Rails.logger.warn("Evaluations::RescheduleService validation failed: #{error.message}")
    end
  end
end
