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

  # Staff may upload a certification unless one awaits review or is already approved; a new file
  # would otherwise replace it. A rejected certification can be replaced. Secure provider forms
  # follow their own request rules.
  def staff_certification_upload_allowed?
    !medical_certification_status.in?(%w[received approved])
  end

  # Determines if medical certification has been approved
  def medical_certification_status_approved?
    medical_certification_status == 'approved'
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
end
