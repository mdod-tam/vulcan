# frozen_string_literal: true

module Applications
  # Service for reviewing and managing medical certification documents
  # Handles rejection workflow including notifications to provider and application status updates
  class MedicalCertificationReviewer < BaseService
    attr_reader :application, :admin

    def initialize(application, admin)
      super() # Initialize BaseService
      @application = application
      @admin = admin
    end

    # Reject a medical certification with a specific reason
    # Updates application status and notifies provider
    # @param rejection_reason [String] The reason for rejection
    # @param notes [String, nil] Optional additional notes for internal use
    # @param rejection_reason_code [String, nil] Stable code for locale-aware resolution (e.g. missing_signature)
    # @return [BaseService::Result] Result object with success status and any error messages
    def reject(rejection_reason:, notes: nil, rejection_reason_code: nil)
      Rails.logger.info "Rejecting medical certification for Application ##{application.id}"

      # Validate all inputs and prerequisites
      validation_result = validate_rejection_inputs(rejection_reason)
      return validation_result if validation_result.failure?

      # Process the rejection through the dedicated service
      service_result = process_rejection(rejection_reason, notes, rejection_reason_code)
      return service_result if service_result.failure?

      # Create additional note if provided
      note_result = create_rejection_note(notes)
      return note_result if note_result.failure?

      success('Disability certification rejected successfully')
    end

    private

    def validate_rejection_inputs(rejection_reason)
      return failure('Rejection reason is required') if rejection_reason.blank?
      return failure('Admin user is required') if admin.blank?

      success
    end

    def process_rejection(rejection_reason, notes, rejection_reason_code)
      service_result = MedicalCertificationAttachmentService.reject_certification(
        application: application,
        admin: admin,
        reason: rejection_reason,
        notes: notes,
        reason_code: rejection_reason_code
      )

      return failure(service_result[:error]&.message || 'Disability certification service failed') unless service_result[:success]

      secure_upload_request = request_secure_certification_upload

      # Notify provider via fax/email channel and attach delivery metadata to the same notification record
      notify_medical_provider(
        rejection_reason,
        service_result[:notification_id],
        secure_upload_url: secure_upload_request.data[:secure_upload_url]
      )

      success
    end

    def request_secure_certification_upload
      result = Applications::RequestCertificationUpload.new(
        application: application,
        actor: admin,
        deliver_email: false
      ).call

      return result if result.success?

      Rails.logger.warn(
        "Secure cert upload form not sent for rejected certification on application #{application.id}: #{result.message}"
      )
      success(nil, { secure_upload_url: nil })
    rescue StandardError => e
      Rails.logger.warn(
        "Secure cert upload form not sent for rejected certification on application #{application.id}: #{e.message}"
      )
      success(nil, { secure_upload_url: nil })
    end

    def notify_medical_provider(rejection_reason, notification_id, secure_upload_url: nil)
      MedicalProviderNotifier.new(application).send_certification_rejection_notice(
        rejection_reason: rejection_reason,
        admin: admin,
        notification_id: notification_id,
        secure_upload_url: secure_upload_url
      )
    rescue StandardError => e
      # Log but don't fail the reviewer - the rejection already succeeded (DB updated, notification created)
      Rails.logger.error("Provider notification failed for application #{application.id}: #{sanitize_secure_error_message(e.message)}")
      Rails.logger.error(sanitize_secure_error_message(e.backtrace.join("\n")))

      # Optional: Report to error tracking service if available
      # Sentry.capture_exception(e) if defined?(Sentry)

      # Provider notification failure doesn't prevent rejection from succeeding
      # Admin can manually contact provider if needed
    end

    def create_rejection_note(notes)
      return success if notes.blank?

      begin
        application.application_notes.create!(
          admin: admin,
          content: "Disability certification rejected: #{notes}"
        )
        success
      rescue StandardError => e
        Rails.logger.error("Failed to create application note: #{e.message}")
        failure("Disability certification rejected successfully, but note creation failed: #{e.message}")
      end
    end
  end
end
