# frozen_string_literal: true

module TrainingSessions
  # Service object to handle updating the status of a training session.
  # This service encapsulates the logic for status transitions, parameter validation,
  # and event creation, reducing complexity in the controller.
  class UpdateStatusService < BaseService
    def initialize(training_session, current_user, params)
      super()
      @training_session = training_session
      @current_user = current_user
      @params = params
      @old_status = @training_session.status
      @new_status = @params[:training_session][:status]
    end

    def call
      ActiveRecord::Base.transaction do
        clear_reason_fields
        handle_status_transition
        create_event
      end

      success(message: 'Training session status updated successfully.', data: { training_session: @training_session })
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Error updating training session status: #{e.message}")
      failure(message: e.message)
    rescue ArgumentError => e
      Rails.logger.error("Invalid parameters for updating training session status: #{e.message}")
      failure(message: e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error updating training session status: #{e.message}")
      failure(message: "An unexpected error occurred: #{e.message}")
    end

    private

    def clear_reason_fields
      @training_session.cancellation_reason = nil if @old_status == 'cancelled' && @new_status != 'cancelled'
      @training_session.no_show_notes = nil if @old_status == 'no_show' && @new_status != 'no_show'
    end

    def handle_status_transition
      Rails.logger.debug { "Status transition: #{@old_status} -> #{@new_status}" }

      if %w[cancelled no_show].include?(@old_status) && @new_status == 'scheduled'
        handle_reschedule_from_cancelled_or_no_show
      else
        perform_normal_update
      end
    end

    def handle_reschedule_from_cancelled_or_no_show
      scheduled_for = @params[:training_session][:scheduled_for]
      Rails.logger.debug { "Forced transition with scheduled_for: #{scheduled_for}" }

      raise ArgumentError, "scheduled_for is required when changing from #{@old_status} to scheduled" if scheduled_for.blank?

      @training_session.assign_attributes(status: 'scheduled', scheduled_for: scheduled_for)
      @training_session.save!(validate: false) # Bypass validations if needed
      Rails.logger.debug { "Forced save result: true, errors: #{@training_session.errors.full_messages}" }
    end

    def perform_normal_update
      permitted_params = determine_permitted_params
      Rails.logger.debug { "Permitted parameters: #{permitted_params.inspect}" }
      @training_session.update!(permitted_params)
      Rails.logger.debug { "Regular update result: true, errors: #{@training_session.errors.full_messages}" }
    end

    def determine_permitted_params
      if @new_status == 'no_show'
        @params.expect(training_session: %i[status no_show_notes])
      elsif @new_status == 'scheduled' && %w[cancelled no_show].include?(@old_status)
        @params.expect(training_session: %i[status scheduled_for])
      else
        @params.require(:training_session).permit(:status, :notes, :scheduled_for, :reschedule_reason, :cancellation_reason, :product_trained_on_id)
      end
    end

    def create_event
      case @new_status
      when 'no_show'
        AuditEventService.log(
          actor: @current_user,
          action: 'training_no_show',
          auditable: @training_session,
          metadata: {
            application_id: @training_session.application_id,
            training_session_id: @training_session.id,
            no_show_notes: @training_session.no_show_notes,
            timestamp: Time.current.iso8601
          }
        )
      else
        # Fallback to generic status change event for other status updates
        AuditEventService.log(
          actor: @current_user,
          action: 'training_status_changed',
          auditable: @training_session,
          metadata: {
            application_id: @training_session.application_id,
            training_session_id: @training_session.id,
            old_status: @old_status,
            new_status: @training_session.status,
            timestamp: Time.current.iso8601
          }
        )
      end
    end
  end
end
