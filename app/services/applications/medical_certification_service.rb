# frozen_string_literal: true

module Applications
  class MedicalCertificationService < BaseService
    attr_reader :application, :actor

    def initialize(application:, actor:)
      super()
      @application = application
      @actor = actor
    end

    def request_certification
      # Validate medical provider email
      return failure(message: 'Medical provider email is required') if application.medical_provider_email.blank?

      # Get current time once to ensure consistency
      current_time = Time.current

      begin
        # Main updates in a transaction
        ApplicationRecord.transaction do
          update_certification_status(current_time)
          increment_request_count(current_time)
        end

        # Ensure application is reloaded after transaction commits
        application.reload

        # Create notification outside the transaction
        notification = create_notification(current_time)

        # Send email with notification for tracking
        send_email(notification)

        success(message: 'Disability certification requested successfully.')
      rescue StandardError => e
        log_error(e, "Application ID: #{application.id}")
        failure(message: "Failed to request disability certification: #{e.message}")
      end
    end

    private

    def update_certification_status(timestamp)
      previous_status = application.medical_certification_status

      # Update the application columns directly to bypass callbacks
      application.update_columns(
        medical_certification_requested_at: timestamp,
        medical_certification_status: Application.medical_certification_statuses[:requested],
        updated_at: timestamp # Ensure timestamp is updated for audit purposes
      )

      # Create ApplicationStatusChange record for activity history
      ApplicationStatusChange.create!(
        application: application,
        user: actor,
        from_status: previous_status || 'not_requested',
        to_status: 'requested',
        metadata: {
          change_type: 'medical_certification',
          requested_at: timestamp.iso8601,
          requested_by_id: actor&.id,
          provider_name: application.medical_provider_name,
          provider_email: application.medical_provider_email
        }
      )

      # Create event for audit trail with clear context
      AuditEventService.log(
        action: 'medical_certification_requested',
        actor: actor,
        auditable: application,
        metadata: {
          old_status: previous_status || 'not_requested',
          new_status: 'requested',
          change_type: 'medical_certification',
          provider_name: application.medical_provider_name,
          submission_method: 'email'
        }
      )
    end

    def increment_request_count(timestamp)
      new_count = (application.medical_certification_request_count || 0) + 1
      application.update_columns(
        medical_certification_request_count: new_count,
        updated_at: timestamp
      )
    end

    def create_notification(_timestamp)
      # Check for existing notification with this request count
      request_count = application.medical_certification_request_count
      existing_notification = Notification.find_by(
        recipient: application.user,
        action: 'medical_certification_requested',
        notifiable: application,
        metadata: { 'request_count' => request_count }
      )

      if existing_notification
        # Log the attempt to create a duplicate
        Rails.logger.warn "Prevented duplicate notification for Application ##{application.id} request_count=#{request_count}"

        # Return the existing notification
        return existing_notification
      end

      # Use NotificationService for centralized notification creation
      NotificationService.create_and_deliver!(
        type: 'medical_certification_requested',
        recipient: application.user,
        actor: actor,
        notifiable: application,
        metadata: {
          request_count: request_count,
          provider: application.medical_provider_name,
          provider_email: application.medical_provider_email
        },
        channel: :email
      )
    rescue StandardError => e
      # Log but don't fail the process
      log_error(e, 'Failed to create notification')
      nil
    end

    def send_email(notification)
      # Queue email delivery to background job instead of immediate delivery
      # This prevents email failures from blocking the request process
      MedicalCertificationEmailJob.perform_later(
        application_id: application.id,
        timestamp: Time.current.iso8601,
        notification_id: notification&.id
      )
    rescue StandardError => e
      # Still log the error if job enqueuing fails
      log_error(e, 'Failed to enqueue email job')
      # We don't re-raise here to prevent job failures from stopping the process
    end
  end
end
