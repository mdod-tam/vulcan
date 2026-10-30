# frozen_string_literal: true

# Certification status predicates, rejection-review readers, and the certification status writer for Application.
module CertificationManagement
  extend ActiveSupport::Concern

  # Rejection details come from ProofReview records.
  def latest_disability_certification_rejection_review
    proof_reviews
      .where(proof_type: :disability_certification, status: :rejected)
      .order(created_at: :desc)
      .first
  end

  def disability_certification_rejection_reason
    latest_disability_certification_rejection_review&.rejection_reason
  end

  def disability_certification_rejection_reason_code
    latest_disability_certification_rejection_review&.rejection_reason_code
  end

  def disability_certification_requested?
    disability_certification_requested_at.present? ||
      disability_certification_status.in?(%w[requested received approved rejected])
  end

  # A staff upload must not replace a certification that awaits review or is approved.
  # A rejected certification can be replaced. Secure provider forms have separate request rules.
  def staff_certification_upload_allowed?
    !disability_certification_status.in?(%w[received approved])
  end

  # Secure provider links follow the proof rule for a closed application (see
  # ProofManageable#proof_requestable_via_secure_form?). Certification status is not part of it: an upload
  # after approval or receipt is kept aside by DisabilityCertificationAttachmentService.accept_submission.
  # Issuance, the admin send button, and public submission all use this rule.
  def certification_requestable_via_secure_form?
    !status_archived?
  end

  def disability_certification_status_approved?
    disability_certification_status == 'approved'
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

  # The one writer of the certification status. It moves the status, records its history row, and logs its
  # audit event in one transaction, as transition_status! does for the application status. A repeat of the
  # current status is still recorded: a second rejection is a new decision.
  #
  # actor:      who made the change; required
  # action:     audit action; request flows name the request instead of a status change
  # attributes: other columns that change with it, such as verification or the request timestamp and count
  # metadata:   stored on the history row and the audit event
  # notes:      stored on the history row only
  #
  # The audit event gets its own operation id, so a second change within the audit dedup window is not dropped.
  # Returns the history row.
  def transition_disability_certification_status!(new_status, actor:, action: 'disability_certification_status_changed',
                                                  attributes: {}, metadata: {}, notes: nil)
    raise ArgumentError, 'actor is required' if actor.blank?

    with_lock do
      old_status = disability_certification_status
      update!(attributes.merge(disability_certification_status: new_status))

      details = { change_type: 'disability_certification' }.merge(metadata)
      change = status_changes.create!(
        from_status: old_status, to_status: disability_certification_status, user: actor, notes: notes,
        change_type: :disability_certification, metadata: notes.present? ? details.merge(notes: notes) : details
      )
      audit_metadata = details.merge(application_id: id, old_status: old_status, new_status: disability_certification_status)
      AuditEventService.log(action: action, actor: actor, auditable: self,
                            metadata: audit_metadata.reverse_merge(operation_id: "disability-certification-status-change-#{change.id}"))
      change
    end
  end
end
