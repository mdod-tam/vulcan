# frozen_string_literal: true

module TrainingSessions
  # Service object to handle cancelling a training session.
  # This service encapsulates the logic for updating the training session status
  # to cancelled, validating required parameters, and creating the associated event.
  class CancelService < BaseService
    def initialize(training_session, current_user, params, cancellation_initiator: nil)
      super()
      @training_session = training_session
      @current_user = current_user
      @params = params
      @cancellation_initiator = cancellation_initiator
    end

    def call
      validate_params!

      ActiveRecord::Base.transaction do
        update_training_session!
        create_event!
      end

      success('Training session cancelled successfully.', { training_session: @training_session })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error cancelling training session: #{e.message}")
      failure(e.message)
    rescue ArgumentError => e
      log_validation_failure(e)
      failure(e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error cancelling training session: #{e.message}")
      failure("An unexpected error occurred: #{e.message}")
    end

    private

    def validate_params!
      return if @params[:cancellation_reason].present?

      raise ArgumentError, 'cancellation_reason is required'
    end

    def log_validation_failure(error)
      Rails.logger.warn("TrainingSessions::CancelService validation failed: #{error.message}")
    end

    def update_training_session!
      @training_session.update!(
        status: :cancelled,
        cancelled_at: Time.current,
        cancellation_reason: @params[:cancellation_reason],
        cancellation_initiator: cancellation_initiator,
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
          cancellation_initiator: @training_session.cancellation_initiator,
          timestamp: Time.current.iso8601
        }
      )
    end

    def cancellation_initiator
      @cancellation_initiator || (@current_user&.admin? ? :admin : :trainer)
    end
  end
end
