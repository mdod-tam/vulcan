# frozen_string_literal: true

module ProofConsistencyValidation
  extend ActiveSupport::Concern

  included do
    validate :newly_approved_proofs_are_attached
  end

  private

  # Approving a proof needs the file it approves. Only the save that approves it is checked, so a later save of an
  # application whose proof is already approved does not depend on who is saving it. A new record or a draft has
  # nothing to approve yet, and a paper submission keeps its proofs on paper.
  def newly_approved_proofs_are_attached
    return if new_record? || status_draft? || submission_method_paper?

    check_newly_approved(:income_proof) if income_proof_required?
    check_newly_approved(:residency_proof)
    check_newly_approved(:id_proof)
  end

  def check_newly_approved(proof_name)
    return unless public_send(:"will_save_change_to_#{proof_name}_status?", to: 'approved')
    return if public_send(proof_name).attached?

    errors.add(proof_name, 'must be attached when status is approved')
  end
end
