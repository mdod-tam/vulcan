# frozen_string_literal: true

# Provides proof attachments, content type and size validation, required-attachment validation,
# approval checks, and review timestamps.
# Attachment and review services own their workflows.
#
# @example Basic usage
#   application = Application.find(123)
#   application.all_proofs_approved?  # => true/false
#   application.can_submit_proof?     # => true/false
#
# @see ProofAttachmentService For file upload operations
# @see Applications::ProofReviewer For review workflow management
# @see ProofReview For review record management
module ProofManageable
  extend ActiveSupport::Concern

  ALLOWED_TYPES = ProofUploadFormats::ALLOWED_CONTENT_TYPES

  PROOF_TYPES = %w[income residency].freeze

  included do
    has_one_attached :income_proof
    has_one_attached :residency_proof
    has_many_attached :documents

    validate :correct_proof_mime_type
    validate :proof_size_within_limit
    validate :require_proof_attachments, if: :require_proof_validations?

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

  # Secure proof links serve a rejected proof or a proof that was never uploaded.
  # Issuance, the admin send button, and public submission all use this rule.
  def proof_requestable_via_secure_form?(proof_type)
    return false if proof_type.to_s == 'income' && !income_proof_required?
    return false if public_send("#{proof_type}_proof_status_approved?")
    return true if public_send("#{proof_type}_proof_status_rejected?")

    public_send("#{proof_type}_proof_status_not_reviewed?") && !public_send("#{proof_type}_proof").attached?
  end

  # The constituent portal accepts only a replacement for a rejected proof.
  def proof_resubmittable_via_portal?(proof_type)
    public_send("#{proof_type}_proof_status_rejected?")
  end

  # Writes the status with no review record or audit. Only tests call it now.
  # @param proof_type [String] The type of proof ('income' or 'residency')
  # @param status [String] The new status ('approved', 'rejected', 'not_reviewed')
  def update_proof_status!(proof_type, status)
    status_attr = "#{proof_type}_proof_status"
    update!(status_attr => status)
  end

  # Records rejection status without a file. ProofAttachmentService owns rejection orchestration.
  # Do not call ProofAttachmentService from here, because that service calls this method.
  def reject_proof_without_attachment!(proof_type, admin: nil, reason: 'other', notes: nil)
    status_attr = "#{proof_type}_proof_status"
    update!(status_attr => :rejected)

    Rails.logger.info "Rejected #{proof_type} proof for app #{id} by #{admin&.id || 'system'} (#{reason})"
    Rails.logger.debug { "Rejection notes: #{notes}" } if notes.present?

    true
  end
  # rubocop:enable Naming/PredicateMethod

  # Purges all proof attachments. Resets only the income and residency statuses.
  # @param admin_user [User] must be an admin
  # @return [Boolean] false if the purge fails
  def purge_proofs(admin_user)
    # TODO: Create ProofPurgeService to handle this logic
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
    Rails.logger.error "Failed to purge proofs: #{e.message}"
    false
  end

  # Applications::ProofReviewer calls this after it sets the rejected status.
  def purge_rejected_proof(proof_type_key)
    attachment_name = :"#{proof_type_key}_proof"
    attachment = public_send(attachment_name)

    return unless attachment.attached?

    Rails.logger.info "[ProofManageable] Purging #{attachment_name} for App ##{id}."
    attachment.purge_later
  end

  private

  # These validations check only blob metadata, on every validation of an attached proof.
  def correct_proof_mime_type
    ProofUploadFormats::PROOF_ATTACHMENT_TYPES.each do |proof_type|
      attachment = send("#{proof_type}_proof")
      next unless attachment.attached?

      errors.add(:"#{proof_type}_proof", "must be a PDF or an image file (#{ProofUploadFormats::HUMAN_LABEL})") unless ALLOWED_TYPES.include?(attachment.content_type)
    end
  end

  def proof_size_within_limit
    ProofUploadFormats::PROOF_ATTACHMENT_TYPES.each do |proof_type|
      attachment = send("#{proof_type}_proof")
      next unless attachment.attached?
      next if ProofUploadFormats.proof_size_allowed?(attachment.byte_size)

      errors.add(:"#{proof_type}_proof",
                 "is too large. Maximum size allowed is #{ProofUploadFormats.proof_max_megabytes}MB.")
    end
  end

  # A rejected proof can have no attachment until the constituent resubmits.
  def require_proof_attachments
    return if new_record? || status_draft?

    if income_proof_required? && !income_proof_status_rejected? && !income_proof.attached?
      errors.add(:income_proof, 'must be attached. Please upload your income documentation.')
    end

    return if residency_proof_status_rejected? || residency_proof.attached?

    errors.add(:residency_proof, 'must be attached. Please upload your proof of Maryland residency.')
  end

  def require_proof_validations?
    return false if skip_validation_contexts?
    return false if new_record? || status_draft?

    submitted? || transitioning_from_draft?
  end

  def skip_validation_contexts?
    (Rails.env.test? && ENV['REQUIRE_PROOF_VALIDATIONS'] != 'true') ||
      Current.skip_proof_validation ||
      Current.reviewing_single_proof? ||
      Current.paper_context? ||
      Current.proof_attachment_service_context? ||
      submission_method_paper?
  end

  def transitioning_from_draft?
    saved_change_to_status? && status_before_last_save == 'draft'
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
      Rails.logger.error "Error setting needs_review_since: #{e.message}"
    ensure
      @setting_review_timestamp = false
    end
  end
end
