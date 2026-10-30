# frozen_string_literal: true

# Provides proof eligibility, required-attachment validation, approval checks, and review timestamps.
# Application declares attachments. DocumentValidator enforces type and size policy.
# ProofAttachmentService owns file uploads, Applications::ProofReviewer owns the review workflow, and ProofReview
# records each review.
module ProofManageable
  extend ActiveSupport::Concern

  included do
    validates :income_proof, :residency_proof, :id_proof, document: { purpose: :proof }
    validate :require_proof_attachments, if: :proofs_due_on_submission?

    after_save :set_needs_review_timestamp, if: :proof_attachments_changed?
  end

  # Alias of Application#required_proofs_approved?.
  def all_proofs_approved?
    required_proofs_approved?
  end

  # Alias of Application#required_proofs_approved? for the DCF escalation trigger.
  def required_proofs_for_dcf_approved?
    required_proofs_approved?
  end

  def can_submit_proof?
    !status_archived? && !status_approved?
  end

  # The attachment for a document type: income, residency, id, or disability_certification.
  def document_attachment_for(type)
    public_send(DocumentType.fetch(type).attachment_name)
  end

  # Secure proof links serve rejected proofs or missing proofs with not_reviewed status.
  # An archived application is closed: ProofReview refuses to review it, so an upload could never be reviewed.
  # Issuance, the admin send button, and public submission all use this rule.
  def proof_requestable_via_secure_form?(proof_type)
    return false if status_archived?
    return false if proof_type.to_s == 'income' && !income_proof_required?
    return false if public_send("#{proof_type}_proof_status_approved?")
    return true if public_send("#{proof_type}_proof_status_rejected?")

    public_send("#{proof_type}_proof_status_not_reviewed?") && !document_attachment_for(proof_type).attached?
  end

  # The constituent portal accepts only a replacement for a rejected proof.
  def proof_resubmittable_via_portal?(proof_type)
    public_send("#{proof_type}_proof_status_rejected?")
  end

  # Records rejection status without a file. The service owns rejection orchestration.
  def reject_proof_without_attachment!(proof_type, admin: nil, reason: 'other', notes: nil)
    status_attr = "#{proof_type}_proof_status"
    update!(status_attr => :rejected)

    Rails.logger.info "Rejected #{proof_type} proof for app #{id} by #{admin&.id || 'system'} " \
                      "(reason_present=#{reason.present?}, notes_present=#{notes.present?})"

    true
  end

  # Clears the review marker alone, without resubmitting the application's intake fields to validation.
  def clear_review_marker!
    return if update_column(:needs_review_since, nil, touch: true) # rubocop:disable Rails/SkipsModelValidations -- Review bookkeeping only.

    raise ActiveRecord::RecordNotSaved.new('Review marker was not cleared.', self)
  end

  # Purges all proof attachments. Resets only the income and residency statuses.
  # @param admin_user [User] must be an admin
  # @return [Boolean] false if the purge fails
  def purge_proofs(admin_user)
    raise ArgumentError, 'Admin user required' unless admin_user&.admin?

    transaction do
      income_proof.purge if income_proof.attached?
      residency_proof.purge if residency_proof.attached?
      id_proof.purge if id_proof.attached?
      update!(income_proof_status: :not_reviewed, residency_proof_status: :not_reviewed,
              last_proof_submitted_at: nil, needs_review_since: nil)
    end
    true
  rescue StandardError => e
    Rails.logger.error "Failed to purge proofs for application #{id}: #{e.class.name}"
    false
  end

  # Applications::ProofReviewer calls this after it sets the rejected status.
  def purge_rejected_proof(proof_type_key)
    attachment = document_attachment_for(proof_type_key)

    return unless attachment.attached?

    Rails.logger.info "[ProofManageable] Purging #{attachment.name} for App ##{id}."
    attachment.purge_later
  end

  private

  # A rejected proof can have no attachment until the constituent resubmits.
  def require_proof_attachments
    if income_proof_required? && !income_proof_status_rejected? && !income_proof.attached?
      errors.add(:income_proof, 'must be attached. Please upload your income documentation.')
    end

    return if residency_proof_status_rejected? || residency_proof.attached?

    errors.add(:residency_proof, 'must be attached. Please upload your proof of Maryland residency.')
  end

  # The required proofs are due when an application leaves draft. A later save does not check them again, so the
  # services that change proof state mid-flow need no way to switch the check off. A paper submission brings its
  # proofs on paper.
  def proofs_due_on_submission?
    !new_record? && !submission_method_paper? && will_save_change_to_status?(from: 'draft')
  end

  def proof_attachments_changed?
    return false if new_record?

    if respond_to?(:attachment_changes) && attachment_changes.present?
      return (FeatureFlag.income_proof_required? && attachment_changes['income_proof'].present?) ||
             attachment_changes['residency_proof'].present? ||
             attachment_changes['id_proof'].present?
    end

    false
  end

  # update! runs after_save again. The flag stops that recursion.
  def set_needs_review_timestamp
    return if @setting_review_timestamp
    return if Current.proof_attachment_service_context?
    return unless (FeatureFlag.income_proof_required? && income_proof.attached?) || residency_proof.attached? || id_proof.attached?

    @setting_review_timestamp = true

    begin
      update!(needs_review_since: Time.current)
      Rails.logger.info "Set needs_review_since for application #{id}"
    rescue StandardError => e
      Rails.logger.error "Error setting needs_review_since for application #{id}: #{e.class.name}"
    ensure
      @setting_review_timestamp = false
    end
  end
end
