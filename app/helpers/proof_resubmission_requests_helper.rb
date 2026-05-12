# frozen_string_literal: true

module ProofResubmissionRequestsHelper
  def show_secure_proof_resubmission_button?(application, proof_type, secure_request_forms: nil)
    proof_type = proof_type.to_s
    return false unless ProofReview.reviewable_proof_type?(proof_type)
    return false if proof_type == 'income' && !application.income_proof_required?
    return false if application.public_send("#{proof_type}_proof_status_approved?")
    return false if active_secure_proof_resubmission_request?(application, proof_type, secure_request_forms: secure_request_forms)

    return true if application.public_send("#{proof_type}_proof_status_rejected?")

    application.public_send("#{proof_type}_proof_status_not_reviewed?") &&
      !application.public_send("#{proof_type}_proof").attached?
  end

  def secure_proof_resubmission_button_text(proof_type)
    "Send Secure #{proof_type.to_s.humanize} Upload Link"
  end

  def active_secure_proof_resubmission_request?(application, proof_type, secure_request_forms: nil)
    forms = secure_request_forms || proof_secure_request_forms(application, proof_type)

    forms.any?(&:active?)
  end

  def proof_secure_request_forms(application, proof_type)
    proof_type = proof_type.to_s
    return SecureRequestForm.none unless ProofReview.reviewable_proof_type?(proof_type)

    application.secure_request_forms
               .public_send("#{proof_type}_proof")
               .includes(:recipient)
               .order(sent_at: :desc)
  end

  def proof_secure_request_forms_label(proof_type)
    t("secure_proof_forms.proof_types.#{proof_type}",
      default: proof_type.to_s.humanize)
  end
end
