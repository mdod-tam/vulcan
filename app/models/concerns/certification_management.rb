# frozen_string_literal: true

# Handles all operations related to medical certification management
# This includes requesting, receiving, and verifying medical certifications
module CertificationManagement
  extend ActiveSupport::Concern

  # Latest medical-certification rejection review for the application.
  # Centralized so legacy call sites can read a unified source of truth.
  def latest_medical_rejection_review
    proof_reviews
      .where(proof_type: :medical_certification, status: :rejected)
      .order(created_at: :desc)
      .first
  end

  # Backward-compatible reader for medical certification rejection reason.
  # Data now comes from ProofReview records.
  def medical_certification_rejection_reason
    latest_medical_rejection_review&.rejection_reason
  end

  # Backward-compatible reader for medical certification rejection reason code.
  # Data now comes from ProofReview records.
  def medical_certification_rejection_reason_code
    latest_medical_rejection_review&.rejection_reason_code
  end

  # Determines if medical certification has been requested
  def medical_certification_requested?
    medical_certification_requested_at.present? ||
      medical_certification_status.in?(%w[requested received approved rejected])
  end

  # Determines if medical certification has been approved
  def medical_certification_status_approved?
    medical_certification_status == 'approved'
  end

  # Updates the certification with the given status and reviewer
  # @param certification [ActionDispatch::Http::UploadedFile] The uploaded certification file
  # @param status [String] The new status ('approved', 'rejected', 'received')
  # @param verified_by [User] The admin who verified the certification
  # @param rejection_reason [String, nil] Reason for rejection if status is 'rejected'
  # @return [Boolean] True if the certification was updated successfully
  def update_certification!(certification:, status:, verified_by:, rejection_reason: nil)
    Rails.logger.info 'Using MedicalCertificationAttachmentService for certification update'

    result = if status == 'rejected' && rejection_reason.present?
               # Use the reject_certification method for rejections
               MedicalCertificationAttachmentService.reject_certification(
                 application: self,
                 admin: verified_by,
                 reason: rejection_reason,
                 submission_method: 'api',
                 metadata: {
                   api_call: true
                 }
               )
             elsif medical_certification.attached? && certification.blank?
               # Status-only update for existing certification (no new file)
               MedicalCertificationAttachmentService.update_certification_status(
                 application: self,
                 status: status.to_sym,
                 admin: verified_by,
                 submission_method: 'api',
                 metadata: {
                   api_call: true,
                   rejection_reason: rejection_reason
                 }
               )
             else
               # Use the attach_certification method for uploads
               MedicalCertificationAttachmentService.attach_certification(
                 application: self,
                 blob_or_file: certification,
                 status: status.to_sym,
                 admin: verified_by,
                 submission_method: 'api',
                 metadata: {
                   api_call: true,
                   rejection_reason: rejection_reason
                 }
               )
             end

    result[:success]
  rescue StandardError => e
    Rails.logger.error "Failed to update certification: #{e.message}"
    false
  end

  # Determines the type of certification update based on status and params presence
  # @param status [Symbol] The normalized certification status
  # @param params [ActionController::Parameters] The controller parameters
  # @return [Symbol] The type of update (:rejection, :status_update, :new_upload)
  def determine_certification_update_type(status, params)
    return :rejection if rejection_requested?(status, params)
    return :status_update if status_only_update_requested?(params)

    :new_upload
  end

  # Normalizes certification status for consistent handling
  # @param status [String, Symbol] The status from params
  # @return [Symbol, nil] Normalized status symbol or nil
  def normalize_certification_status(status)
    return nil unless status

    status = status.to_sym if status.respond_to?(:to_sym)
    # Convert any 'accepted' to 'approved' for consistency with the Application model enum
    status = :approved if status == :accepted
    status
  end

  # Determines if a certification rejection was requested
  # @param status [Symbol] The normalized status
  # @param params [ActionController::Parameters] The controller parameters
  # @return [Boolean] True if rejection was requested with reason
  def rejection_requested?(status, params)
    status == :rejected && params[:rejection_reason].present?
  end

  # Determines if this is a status-only update (no new file)
  # @param params [ActionController::Parameters] The controller parameters
  # @return [Boolean] True if updating status on existing certification
  def status_only_update_requested?(params)
    medical_certification.attached? && params[:medical_certification].blank?
  end
end
