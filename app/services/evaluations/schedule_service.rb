# frozen_string_literal: true

module Evaluations
  class ScheduleService < BaseService
    def initialize(evaluation, actor, params)
      super()
      @evaluation = evaluation
      @actor = actor
      @params = params
    end

    def call
      validate_params!

      ActiveRecord::Base.transaction do
        schedule_evaluation!
        create_event!
      end

      success('Evaluation scheduled successfully.', { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error scheduling evaluation: #{e.message}")
      failure(e.message)
    rescue ArgumentError => e
      log_validation_failure(e)
      failure(e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error scheduling evaluation: #{e.message}")
      failure("An unexpected error occurred: #{e.message}")
    end

    private

    def validate_params!
      raise ArgumentError, 'evaluation_date is required' if @params[:evaluation_date].blank?
    end

    def schedule_evaluation!
      @evaluation.update!(
        evaluation_date: @params[:evaluation_date],
        location: @params[:location],
        notes: @params[:notes],
        status: :scheduled
      )
    end

    def create_event!
      AuditEventService.log(
        action: 'evaluation_scheduled',
        actor: @actor,
        auditable: @evaluation,
        metadata: {
          evaluation_id: @evaluation.id,
          application_id: @evaluation.application_id,
          evaluation_date: @evaluation.evaluation_date&.iso8601,
          location: @evaluation.location,
          notes: @evaluation.notes,
          timestamp: Time.current.iso8601
        }
      )
    end

    def log_validation_failure(error)
      Rails.logger.warn("Evaluations::ScheduleService validation failed: #{error.message}")
    end
  end
end
