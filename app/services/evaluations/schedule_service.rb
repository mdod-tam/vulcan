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
      @evaluation.application.with_lock do
        @evaluation.with_lock do
          validate_params!
          schedule_evaluation!
          create_event!
        end
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
      raise ArgumentError, 'Only the assigned evaluator can update this evaluation.' unless @evaluation.evaluator_id == @actor&.id

      @evaluation.require_approved_application!
      raise ArgumentError, 'Only requested evaluations can be scheduled.' unless @evaluation.status_requested?

      date_error = if @params[:evaluation_date].blank?
                     'is required'
                   elsif evaluation_date.nil?
                     'must be a valid date/time'
                   elsif evaluation_date <= Time.current
                     'must be in the future'
                   end
      return if date_error.nil?

      @evaluation.errors.add(:evaluation_date, date_error)
      raise ArgumentError, "evaluation_date #{date_error}"
    end

    def schedule_evaluation!
      @evaluation.update!(
        evaluation_date: evaluation_date,
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

    def evaluation_date
      @evaluation_date ||= begin
        value = @params[:evaluation_date]
        value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
