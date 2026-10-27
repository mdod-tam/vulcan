# frozen_string_literal: true

module ProofConsistencyValidation
  extend ActiveSupport::Concern

  included do
    validate :validate_proof_status_consistent_with_application_status, unless: :skip_proof_validation?
  end

  def validate_proof_status_consistent_with_application_status
    proofs_consistent_with_status
  end

  # Paper intake, ProofAttachmentService, purges and single-proof reviews manage proof state themselves,
  # and the reviewer validates the selected proof. A new record or a draft has nothing to check yet.
  def skip_proof_validation?
    return true if Current.paper_context?
    return true if Current.proof_attachment_service_context?
    return true if Current.skip_proof_validation?
    return true if Current.reviewing_single_proof?
    return true if new_record?
    return true if status_draft?

    false
  end

  private

  def proofs_consistent_with_status
    return if submission_method&.to_sym == :paper

    check_proof_consistency(:income_proof, income_proof_status, income_proof) if income_proof_required?
    check_proof_consistency(:residency_proof, residency_proof_status, residency_proof)
    check_proof_consistency(:id_proof, id_proof_status, id_proof)
  end

  def check_proof_consistency(proof_sym, status, attachment)
    # Only an approved proof needs an attachment. A rejected proof can have none, either because it came
    # from a paper application or because it awaits resubmission.
    return unless status == 'approved' && !attachment.attached?

    errors.add(proof_sym, "must be attached when status is #{status}")
  end
end
