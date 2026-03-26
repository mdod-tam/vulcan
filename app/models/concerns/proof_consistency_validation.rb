# frozen_string_literal: true

module ProofConsistencyValidation
  extend ActiveSupport::Concern

  included do
    validate :validate_proof_status_consistent_with_application_status, unless: :skip_proof_validation?
  end

  # Validation method for proof status consistency with application status
  def validate_proof_status_consistent_with_application_status
    proofs_consistent_with_status
  end

  # Helper method to check if proof validation should be skipped
  def skip_proof_validation?
    # Skip during paper application processing
    return true if Current.paper_context?

    # Skip during service operations that manage their own consistency
    return true if Current.proof_attachment_service_context?

    # Skip during administrative actions like purging proofs
    return true if Current.skip_proof_validation?

    # Skip for new records (attachments handled during creation)
    return true if new_record?

    # Skip for draft applications
    return true if status_draft?

    false
  end

  private

  def proofs_consistent_with_status
    # Skip validation for paper applications
    return if submission_method&.to_sym == :paper

    check_proof_consistency(:income_proof, income_proof_status, income_proof) if income_proof_required?
    check_proof_consistency(:residency_proof, residency_proof_status, residency_proof)
  end

  def check_proof_consistency(proof_sym, status, attachment)
    # Only validate approved proofs must have attachments
    # Rejected proofs can exist without attachments (paper applications)
    # or can be in the process of resubmission
    return unless status == 'approved' && !attachment.attached?

    errors.add(proof_sym, "must be attached when status is #{status}")
  end
end
