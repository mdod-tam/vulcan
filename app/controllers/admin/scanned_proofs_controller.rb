# frozen_string_literal: true

module Admin
  class ScannedProofsController < Admin::BaseController
    # Include RedirectHelper concern to provide standardized redirect methods
    # This replaces manual redirect_to calls with consistent redirect_with_notice/redirect_with_alert
    # that take (path, message) parameters for better code organization
    include RedirectHelper

    before_action :set_application
    before_action :validate_proof_type, only: %i[new create]
    before_action :validate_file, only: [:create]

    ALLOWED_CONTENT_TYPES = [
      'application/pdf',
      'image/jpeg',
      'image/png',
      'image/tiff'
    ].freeze

    MAX_FILE_SIZE = 10.megabytes

    def new
      @proof_type = params[:proof_type]
    end

    def create
      begin
        # Use ApplicationRecord.transaction for consistency with Rails 7+ and to keep
        # domain logic near your ApplicationRecord base class if needed.
        ApplicationRecord.transaction do
          attach_proof
          # NOTE: audit trail is handled by ProofAttachmentService.attach_proof
        end

        success = true
      rescue ActiveRecord::RecordInvalid, ActiveStorage::IntegrityError => e
        # For record or integrity errors, let the user retry on the form page.
        redirect_to new_admin_application_scanned_proof_path(@application),
                    alert: e.message
        return
      rescue StandardError => e
        # Log any unexpected error and let the user know to try again.
        Rails.logger.error("Proof upload failed: #{e.message}")
        # Using RedirectHelper concern method - provides consistent error handling
        # Flow: redirect_with_alert(path, message) -> redirect_to path, alert: message
        redirect_with_alert(admin_application_path(@application), 'Error uploading proof. Please try again.')
        return
      end

      # Only proceed with notification if the upload was successful
      return unless success

      begin
        # Best practice: run notifications outside the transaction so a rollback
        # doesn't prevent them. Consider using a background job if it's a heavier process.
        notify_constituent
      rescue StandardError => e
        Rails.logger.error("Failed to send notification: #{e.message}")
        # Don't fail the upload if just the notification fails
      end

      # Using RedirectHelper concern method - provides consistent success handling
      # Flow: redirect_with_notice(path, message) -> redirect_to path, notice: message
      redirect_with_notice(admin_application_path(@application), 'Proof successfully uploaded and attached')
    end

    private

    def set_application
      @application = Application.find(params[:application_id])
    rescue ActiveRecord::RecordNotFound
      # Using RedirectHelper concern method for consistent error redirects
      redirect_with_alert(admin_applications_path, 'Application not found')
    end

    def validate_proof_type
      return if %w[income residency].include?(params[:proof_type])

      # Using RedirectHelper concern method for validation error redirects
      redirect_with_alert(admin_application_path(@application), 'Invalid proof type')
    end

    def validate_file
      if params[:file].blank?
        return redirect_to(new_admin_application_scanned_proof_path(@application),
                           alert: t('alerts.file_select'))
      end

      unless valid_file_type?
        return redirect_to(new_admin_application_scanned_proof_path(@application),
                           alert: t('alerts.file_type_not_allowed'))
      end

      return if valid_file_size?

      redirect_to(new_admin_application_scanned_proof_path(@application),
                  alert: "File size must be under #{MAX_FILE_SIZE / 1.megabyte}MB")
    end

    def valid_file_type?
      ALLOWED_CONTENT_TYPES.include?(params[:file].content_type)
    end

    def valid_file_size?
      params[:file].size <= MAX_FILE_SIZE
    end

    def attach_proof
      result = ProofAttachmentService.attach_proof({
                                                     application: @application,
                                                     proof_type: params[:proof_type].to_sym,
                                                     blob_or_file: params[:file],
                                                     status: :approved,
                                                     admin: current_user,
                                                     submission_method: :paper,
                                                     skip_audit_events: true, # Admin controller handles its own audit events
                                                     metadata: {
                                                       scanned_by: current_user.id,
                                                       scan_location: params[:scan_location] || 'central_office'
                                                     }
                                                   })
      raise "Failed to attach proof: #{result[:error]&.message}" unless result[:success]

      # Create tracking event for audit trail (similar to constituent portal)
      track_submission
    end

    def track_submission
      # Get the blob ID from the actually attached blob for consistency with ProofAttachmentService
      # Replace dynamic send with explicit case statement
      attached_blob = case params[:proof_type]
                      when 'income'
                        @application.income_proof.blob
                      when 'residency'
                        @application.residency_proof.blob
                      end

      # Create Event for application audit log (matches constituent portal pattern)
      AuditEventService.log(
        action: 'proof_submitted',
        actor: current_user,
        auditable: @application,
        metadata: {
          proof_type: params[:proof_type],
          submission_method: 'paper',
          success: true,
          blob_id: attached_blob&.id,
          filename: params[:file].original_filename
        }
      )
    end

    def notify_constituent
      ApplicationNotificationsMailer.proof_received(
        @application,
        params[:proof_type]
      ).deliver_later
    rescue StandardError => e
      Rails.logger.error("Failed to queue notification: #{e.message}")
      # Continue without failing the upload
    end
  end
end
