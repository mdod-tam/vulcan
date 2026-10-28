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
      @evaluation.with_actor_and_application_lock(@actor) do
        validate_params!
        schedule_evaluation!
        create_event!
      end

      success('Evaluation scheduled successfully.', { evaluation: @evaluation })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error scheduling evaluation: #{e.class.name}")
      failure(e.message)
    rescue ArgumentError => e
      log_validation_failure(e)
      failure(e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error scheduling evaluation: #{e.class.name}")
      failure('An unexpected error occurred.')
    end

    private

    def validate_params!
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
      Rails.logger.warn("Evaluations::ScheduleService validation failed: #{error.class.name}")
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
