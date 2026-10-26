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
      @evaluation.with_actor_and_application_lock(@actor) do
        validate_params!
        old_evaluation_date = @evaluation.evaluation_date
        reschedule_evaluation!
        create_event!(old_evaluation_date)
      end

      success('Evaluation rescheduled successfully.', { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error rescheduling evaluation: #{e.class.name}")
      failure(e.message)
    rescue ArgumentError => e
      log_validation_failure(e)
      failure(e.message)
    rescue TypeError => e
      log_validation_failure(e)
      failure('evaluation_date must be a valid date/time')
    rescue StandardError => e
      Rails.logger.error("Unexpected error rescheduling evaluation: #{e.class.name}")
      failure("An unexpected error occurred: #{e.message}")
    end

    private

    def validate_params!
      raise ArgumentError, 'Only the assigned evaluator can update this evaluation.' unless @evaluation.evaluator_id == @actor&.id

      @evaluation.require_approved_application!
      raise ArgumentError, 'Only scheduled, confirmed, cancelled, or no-show evaluations can be rescheduled.' unless @evaluation.can_reschedule?

      if required_fields_missing?
        @evaluation.errors.add(:evaluation_date, 'is required') if @params[:evaluation_date].blank?
        @evaluation.errors.add(:reschedule_reason, 'is required') if @params[:reschedule_reason].blank?
        raise ArgumentError, 'evaluation_date and reschedule_reason are required'
      end

      date_error = if evaluation_date.nil?
                     'must be a valid date/time'
                   elsif evaluation_date <= Time.current
                     'must be in the future'
                   end
      return if date_error.nil?

      @evaluation.errors.add(:evaluation_date, date_error)
      raise ArgumentError, "evaluation_date #{date_error}"
    end

    def required_fields_missing?
      @params[:evaluation_date].blank? || @params[:reschedule_reason].blank?
    end

    def reschedule_evaluation!
      @evaluation.update!(
        evaluation_date: evaluation_date,
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
      Rails.logger.warn("Evaluations::RescheduleService validation failed: #{error.class.name}")
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
