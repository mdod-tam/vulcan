# frozen_string_literal: true

module TrainingSessions
  # Service object to handle rescheduling a training session.
  # This service encapsulates the logic for updating the training session's
  # scheduled time and reason, and creating the associated event.
  class RescheduleService < BaseService
    def initialize(training_session, current_user, params)
      super()
      @training_session = training_session
      @current_user = current_user
      @params = params
    end

    def call
      validate_params!

      old_scheduled_for = @training_session.scheduled_for

      ActiveRecord::Base.transaction do
        update_training_session!(old_scheduled_for)
        create_event!(old_scheduled_for)
      end

      success(message: 'Training session rescheduled successfully.', data: { training_session: @training_session })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error rescheduling training session: #{e.message}")
      failure(message: e.message)
    rescue ArgumentError => e
      Rails.logger.error("Invalid parameters for rescheduling training session: #{e.message}")
      failure(message: e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error rescheduling training session: #{e.message}")
      failure(message: "An unexpected error occurred: #{e.message}")
    end

    private

    def validate_params!
      return unless @params[:scheduled_for].blank? || @params[:reschedule_reason].blank?

      raise ArgumentError, 'scheduled_for and reschedule_reason are required'
    end

    def update_training_session!(_old_scheduled_for)
      @training_session.update!(
        scheduled_for: @params[:scheduled_for],
        reschedule_reason: @params[:reschedule_reason],
        status: :scheduled,
        cancellation_reason: nil, # Clear cancellation reason on reschedule
        no_show_notes: nil # Clear no show notes on reschedule
      )
    end

    def create_event!(old_scheduled_for)
      AuditEventService.log(
        actor: @current_user,
        action: 'training_rescheduled',
        auditable: @training_session,
        metadata: {
          application_id: @training_session.application_id,
          training_session_id: @training_session.id,
          old_scheduled_for: old_scheduled_for&.iso8601,
          new_scheduled_for: @training_session.scheduled_for.iso8601,
          reason: @training_session.reschedule_reason,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
