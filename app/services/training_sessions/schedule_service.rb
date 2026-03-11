# frozen_string_literal: true

module TrainingSessions
  # Service object to handle scheduling a training session.
  # This service encapsulates the logic for updating the training session's
  # status to scheduled, validating required parameters, and creating the associated event.
  class ScheduleService < BaseService
    def initialize(training_session, current_user, params)
      super()
      @training_session = training_session
      @current_user = current_user
      @params = params
    end

    def call
      validate_params!

      ActiveRecord::Base.transaction do
        update_training_session!
        create_event!
      end

      success(message: 'Training session scheduled successfully.', data: { training_session: @training_session })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error scheduling training session: #{e.message}")
      failure(message: e.message)
    rescue ArgumentError => e
      log_validation_failure(e)
      failure(message: e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error scheduling training session: #{e.message}")
      failure(message: "An unexpected error occurred: #{e.message}")
    end

    private

    def validate_params!
      raise ArgumentError, 'scheduled_for is required' if @params[:scheduled_for].blank?
    end

    def log_validation_failure(error)
      message = "TrainingSessions::ScheduleService validation failed: #{error.message}"
      return Rails.logger.warn("[EXPECTED_TEST_VALIDATION] #{message}") if Rails.env.test?

      Rails.logger.warn(message)
    end

    def update_training_session!
      @training_session.update!(
        status: :scheduled,
        scheduled_for: @params[:scheduled_for],
        notes: @params[:notes],
        cancellation_reason: nil,
        no_show_notes: nil
      )
    end

    def create_event!
      AuditEventService.log(
        actor: @current_user,
        action: 'training_scheduled',
        auditable: @training_session,
        metadata: {
          application_id: @training_session.application_id,
          training_session_id: @training_session.id,
          scheduled_for: @training_session.scheduled_for&.iso8601,
          notes: @training_session.notes,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
