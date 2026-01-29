# frozen_string_literal: true

# ProofManageable provides proof document management capabilities for applications.
#
# This concern handles the core model-level responsibilities for income and residency
# proof documents, including:
# - ActiveStorage attachment definitions
# - Basic validation of file types and sizes
# - Status checking methods for proof approval states
# - Model-level callbacks for proof state changes
#
# For complex operations like attachment processing, review workflows, and audit
# trails, this concern delegates to dedicated services:
# - ProofAttachmentService: Handles file uploads and audit trails
# - Applications::ProofReviewer: Manages the review process
# - ProofReviewService: Orchestrates proof reviews
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

  # Allowed MIME types for proof documents
  ALLOWED_TYPES = ['application/pdf', 'image/jpeg', 'image/png', 'image/tiff', 'image/bmp'].freeze

  # Maximum file size for proof documents (5MB)
  MAX_FILE_SIZE = 5.megabytes

  # Valid proof types for the application
  PROOF_TYPES = %w[income residency].freeze

  included do
    # ActiveStorage attachments for proof documents
    has_one_attached :income_proof
    has_one_attached :residency_proof
    has_one_attached :medical_certification
    has_many_attached :documents

    # Core validations for proof documents
    validate :correct_proof_mime_type
    validate :proof_size_within_limit
    validate :require_proof_attachments, if: :require_proof_validations?

    # Callbacks for proof state management
    after_save :set_needs_review_timestamp, if: :proof_attachments_changed?
    after_save :notify_admins_of_new_proofs, if: -> { needs_review_since_changed? && needs_review_since.present? }
  end

  # Checks if all required proofs have been approved
  # @return [Boolean] true if both income and residency proofs are approved
  def all_proofs_approved?
    income_proof_status_approved? && residency_proof_status_approved?
  end

  # Checks if all currently required proofs for DCF request have been approved
  # @return [Boolean] true if required proofs are approved
  def required_proofs_for_dcf_approved?
    all_proofs_approved?
  end

  # Checks if the income proof has been rejected
  # @return [Boolean] true if income proof status is rejected
  def rejected_income_proof?
    income_proof_status_rejected?
  end

  # Checks if the residency proof has been rejected
  # @return [Boolean] true if residency proof status is rejected
  def rejected_residency_proof?
    residency_proof_status_rejected?
  end

  # Checks if the application can submit proof documents
  # @return [Boolean] true if application is in a valid state for proof submission
  def can_submit_proof?
    !status_archived? && !status_approved?
  end

  # Updates proof status directly (for testing and admin operations)
  # @param proof_type [String] The type of proof ('income' or 'residency')
  # @param status [String] The new status ('approved', 'rejected', 'not_reviewed')
  def update_proof_status!(proof_type, status)
    status_attr = "#{proof_type}_proof_status"
    update!(status_attr => status)
  end

  # Rejects a proof without requiring an attachment (used for paper applications)
  # This is a model-level method that just updates the status - the service handles orchestration
  def reject_proof_without_attachment!(proof_type, admin: nil, reason: 'other', notes: nil)
    # Just update the proof status - avoid circular calls to ProofAttachmentService
    status_attr = "#{proof_type}_proof_status"
    update!(status_attr => :rejected)

    # Log basic info about rejection (params used to avoid unused warnings)
    Rails.logger.info "Rejected #{proof_type} proof for app #{id} by #{admin&.id || 'system'} (#{reason})"
    Rails.logger.debug { "Rejection notes: #{notes}" } if notes.present?

    true
  end
  # rubocop:enable Naming/PredicateMethod

  # Purges all proof attachments (admin action)
  # Delegates to ProofAttachmentService for consistency
  # @param admin_user [User] The admin user performing the purge
  # @return [Boolean] true if purge succeeded, false otherwise
  def purge_proofs(admin_user)
    # This complex operation should be handled by a dedicated service
    # TODO: Create ProofPurgeService to handle this logic
    raise ArgumentError, 'Admin user required' unless admin_user&.admin?

    # For now, simplified inline implementation
    transaction do
      income_proof.purge if income_proof.attached?
      residency_proof.purge if residency_proof.attached?
      update!(income_proof_status: :not_reviewed, residency_proof_status: :not_reviewed,
              last_proof_submitted_at: nil, needs_review_since: nil)
    end
    true
  rescue StandardError => e
    Rails.logger.error "Failed to purge proofs: #{e.message}"
    false
  end

  # Purges a specific rejected proof attachment
  # Called by ProofReviewer after setting status to rejected
  # @param proof_type_key [String] The type of proof to purge
  def purge_rejected_proof(proof_type_key)
    attachment_name = :"#{proof_type_key}_proof"
    attachment = public_send(attachment_name)

    return unless attachment.attached?

    Rails.logger.info "[ProofManageable] Purging #{attachment_name} for App ##{id}."
    attachment.purge_later
  end

  private

  # Validates that attached proofs have correct MIME types and size limits
  def correct_proof_mime_type
    PROOF_TYPES.each do |proof_type|
      attachment = send("#{proof_type}_proof")
      next unless attachment.attached?

      errors.add(:"#{proof_type}_proof", 'must be a PDF or an image file (jpg, jpeg, png, tiff, bmp)') unless ALLOWED_TYPES.include?(attachment.content_type)
    end
  end

  def proof_size_within_limit
    PROOF_TYPES.each do |proof_type|
      attachment = send("#{proof_type}_proof")
      next unless attachment.attached?
      next if attachment.byte_size <= MAX_FILE_SIZE

      errors.add(:"#{proof_type}_proof", 'is too large. Maximum size allowed is 5MB.')
    end
  end

  # Validates that required proofs are attached when needed
  def require_proof_attachments
    return if new_record? || status_draft?

    errors.add(:income_proof, 'must be attached. Please upload your income documentation.') unless income_proof.attached?

    return if residency_proof.attached?

    errors.add(:residency_proof, 'must be attached. Please upload your proof of Maryland residency.')
  end

  # Determines if proof attachment validations should be required
  # @return [Boolean] true if validations should run
  def require_proof_validations?
    return false if skip_validation_contexts?
    return false if new_record? || status_draft?

    submitted? || transitioning_from_draft?
  end

  def skip_validation_contexts?
    (Rails.env.test? && ENV['REQUIRE_PROOF_VALIDATIONS'] != 'true') ||
      Current.skip_proof_validation ||
      Current.paper_context? ||
      submission_method_paper? # Skip for paper applications (matches ProofConsistencyValidation line 39)
  end

  def transitioning_from_draft?
    saved_change_to_status? && status_before_last_save == 'draft'
  end

  # Detects if proof attachments have changed
  # @return [Boolean] true if attachments were recently changed
  def proof_attachments_changed?
    return false if new_record?

    # Check for attachment changes using Rails' built-in detection
    if respond_to?(:attachment_changes) && attachment_changes.present?
      return attachment_changes['income_proof'].present? ||
             attachment_changes['residency_proof'].present?
    end

    false
  end

  # Sets the needs_review_since timestamp when proofs are attached
  def set_needs_review_timestamp
    return if @setting_review_timestamp
    return if Current.proof_attachment_service_context?
    return unless income_proof.attached? || residency_proof.attached?

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

  # Notifies admins when new proofs require review
  def notify_admins_of_new_proofs
    return unless needs_review_since_changed? && needs_review_since.present?

    NotifyAdminsJob.perform_later(self)
  end
end
