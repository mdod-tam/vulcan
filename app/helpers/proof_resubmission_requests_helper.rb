# frozen_string_literal: true

module ProofResubmissionRequestsHelper
  def show_secure_proof_resubmission_button?(application, proof_type, secure_request_forms: nil)
    proof_type = proof_type.to_s
    return false unless ProofReview.reviewable_proof_type?(proof_type)
    return false if proof_type == 'income' && !application.income_proof_required?
    return false if application.public_send("#{proof_type}_proof_status_approved?")

    forms = secure_request_forms || proof_secure_request_forms(application, proof_type)
    return false if forms.any?(&:active?) && proof_recovery_recipient_ids(forms).empty?

    return true if application.public_send("#{proof_type}_proof_status_rejected?")

    application.public_send("#{proof_type}_proof_status_not_reviewed?") &&
      !application.public_send("#{proof_type}_proof").attached?
  end

  def secure_proof_recipient_options(options, forms)
    return options unless forms.any?(&:active?)

    recovery_ids = proof_recovery_recipient_ids(forms)
    options.select { |option| recovery_ids.include?(option[:recipient].id) }
  end

  def proof_recovery_recipient_ids(forms)
    latest_by_recipient = forms.group_by(&:recipient_id).values.map { |requests| requests.max_by { |form| [form.sent_at, form.id] } }
    revoked_ids = latest_by_recipient.select(&:revoked?).map(&:recipient_id)
    revoked_ids - forms.select(&:active?).map(&:recipient_id)
  end

  def secure_proof_resubmission_button_text(proof_type)
    "Send Secure #{proof_type.to_s.humanize} Upload Link"
  end

  def proof_secure_request_forms(application, proof_type)
    proof_type = proof_type.to_s
    return SecureRequestForm.none unless ProofReview.reviewable_proof_type?(proof_type)

    application.secure_request_forms
               .public_send("#{proof_type}_proof")
               .includes(:recipient, :delivery_owner)
               .order(sent_at: :desc)
  end

  def proof_secure_request_forms_label(proof_type)
    t("secure_proof_forms.proof_types.#{proof_type}",
      default: proof_type.to_s.humanize)
  end
end
