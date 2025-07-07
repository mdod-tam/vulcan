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
    # @return [BaseService::Result] Result object with success status and any error messages
    def reject(rejection_reason:, notes: nil)
      Rails.logger.info "Rejecting medical certification for Application ##{application.id}"

      # Validate all inputs and prerequisites
      validation_result = validate_rejection_inputs(rejection_reason)
      return validation_result if validation_result.failure?

      # Process the rejection through the dedicated service
      service_result = process_rejection(rejection_reason, notes)
      return service_result if service_result.failure?

      # Create additional note if provided
      note_result = create_rejection_note(notes)
      return note_result if note_result.failure?

      success('Medical certification rejected successfully')
    end

    private

    def validate_rejection_inputs(rejection_reason)
      return failure('Rejection reason is required') if rejection_reason.blank?
      return failure('Admin user is required') if admin.blank?

      validate_medical_provider_info
    end

    def validate_medical_provider_info
      return failure('Application does not have medical provider information') if application.medical_provider_name.blank?
      return failure('No contact method available for medical provider') if no_contact_methods_available?

      success
    end

    def no_contact_methods_available?
      application.medical_provider_email.blank? && application.medical_provider_fax.blank?
    end

    def process_rejection(rejection_reason, notes)
      service_result = MedicalCertificationAttachmentService.reject_certification(
        application: application,
        admin: admin,
        reason: rejection_reason,
        notes: notes
      )

      return failure(service_result[:error]&.message || 'Medical certification service failed') unless service_result[:success]

      success
    end

    def create_rejection_note(notes)
      return success if notes.blank?

      begin
        application.application_notes.create!(
          admin: admin,
          content: "Medical certification rejected: #{notes}"
        )
        success
      rescue StandardError => e
        Rails.logger.error("Failed to create application note: #{e.message}")
        failure("Medical certification rejected successfully, but note creation failed: #{e.message}")
      end
    end
  end
end
