# frozen_string_literal: true

# Certification status predicates and rejection-review readers for Application.
module CertificationManagement
  extend ActiveSupport::Concern

  # Rejection details come from ProofReview records.
  def latest_medical_rejection_review
    proof_reviews
      .where(proof_type: :medical_certification, status: :rejected)
      .order(created_at: :desc)
      .first
  end

  def medical_certification_rejection_reason
    latest_medical_rejection_review&.rejection_reason
  end

  def medical_certification_rejection_reason_code
    latest_medical_rejection_review&.rejection_reason_code
  end

  def medical_certification_requested?
    medical_certification_requested_at.present? ||
      medical_certification_status.in?(%w[requested received approved rejected])
  end

  # A staff upload must not replace a certification that awaits review or is approved.
  # A rejected certification can be replaced. Secure provider forms have separate request rules.
  def staff_certification_upload_allowed?
    !medical_certification_status.in?(%w[received approved])
  end

  def medical_certification_status_approved?
    medical_certification_status == 'approved'
  end

  # The review modal submits :accepted, which maps to the :approved enum value.
  # @param status [String, Symbol] The status from params
  # @return [Symbol, nil] Normalized status symbol or nil
  def normalize_certification_status(status)
    return nil unless status

    status = status.to_sym if status.respond_to?(:to_sym)
    status = :approved if status == :accepted
    status
  end

  # A rejection requires both :rejected status and a reason.
  # @param status [Symbol] The normalized status
  # @param params [ActionController::Parameters] The controller parameters
  # @return [Boolean] True if rejection was requested with reason
  def rejection_requested?(status, params)
    status == :rejected && params[:rejection_reason].present?
  end
end
