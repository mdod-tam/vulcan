# frozen_string_literal: true

module TrainingSessions
  # Service object to handle completing a training session.
  # This service encapsulates the logic for updating the training session status
  # to completed, validating required parameters, and creating the associated event.
  class CompleteService < BaseService
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

      success('Training session completed successfully.', { training_session: @training_session })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error completing training session: #{e.message}")
      failure(e.message)
    rescue ArgumentError => e
      log_validation_failure(e)
      failure(e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error completing training session: #{e.message}")
      failure("An unexpected error occurred: #{e.message}")
    end

    private

    def validate_params!
      raise ArgumentError, 'notes is required' if @params[:notes].blank?
      return if @params[:product_trained_on_id].present?

      raise ArgumentError, 'product_trained_on_id is required'
    end

    def log_validation_failure(error)
      Rails.logger.warn("TrainingSessions::CompleteService validation failed: #{error.message}")
    end

    def update_training_session!
      @training_session.update!(
        status: :completed,
        completed_at: Time.current,
        notes: @params[:notes],
        product_trained_on_id: @params[:product_trained_on_id],
        cancellation_reason: nil,
        no_show_notes: nil
      )
    end

    def create_event!
      AuditEventService.log(
        actor: @current_user,
        action: 'training_completed',
        auditable: @training_session,
        metadata: {
          application_id: @training_session.application_id,
          training_session_id: @training_session.id,
          completed_at: @training_session.completed_at&.iso8601,
          notes: @training_session.notes,
          product_trained_on: @training_session.product_trained_on&.name,
          timestamp: Time.current.iso8601
        }
      )
    end
  end
end
