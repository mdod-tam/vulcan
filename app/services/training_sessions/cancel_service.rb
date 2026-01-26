# frozen_string_literal: true

module TrainingSessions
  # Service object to handle cancelling a training session.
  # This service encapsulates the logic for updating the training session status
  # to cancelled, validating required parameters, and creating the associated event.
  class CancelService < BaseService
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

      success(message: 'Training session cancelled successfully.', data: { training_session: @training_session })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error cancelling training session: #{e.message}")
      failure(message: e.message)
    rescue ArgumentError => e
      Rails.logger.error("Invalid parameters for cancelling training session: #{e.message}")
      failure(message: e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error cancelling training session: #{e.message}")
      failure(message: "An unexpected error occurred: #{e.message}")
    end

    private

    def validate_params!
      return if @params[:cancellation_reason].present?

      raise ArgumentError, 'cancellation_reason is required'
    end

    def update_training_session!
      @training_session.update!(
        status: :cancelled,
        cancelled_at: Time.current,
        cancellation_reason: @params[:cancellation_reason],
        notes: nil,
        no_show_notes: nil
      )
    end

    def create_event!
      AuditEventService.log(
        actor: @current_user,
        action: 'training_cancelled',
        auditable: @training_session,
        metadata: {
          application_id: @training_session.application_id,
          training_session_id: @training_session.id,
          cancellation_reason: @training_session.cancellation_reason,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
