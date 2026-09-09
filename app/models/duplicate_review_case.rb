# frozen_string_literal: true

class DuplicateReviewCase < ApplicationRecord
  ALLOWED_METADATA_KEYS = %w[
    reason_codes
    submitted_contact_digest
    intake_context
    subject_snapshot
  ].freeze

  # Structured record of an admin resolution. Stores decision context and codes only;
  # never raw contact values (those come from live records at merge time).
  ALLOWED_RESOLUTION_METADATA_KEYS = %w[
    reason_codes
    canonical_user_id
    merged_user_id
    contact_choices
    delivery_choice
    transfer_summary
    merge_audit_event_id
    replacement_case_id
    superseding_merge_case_id
  ].freeze

  RESOLVED_STATUSES = %w[resolved_approved resolved_ignored resolved_merged resolved_superseded].freeze

  # Reason codes an admin may record on a resolution, as opposed to the detection-derived
  # evidence codes in DuplicateReviewCaseCandidate::MATCH_REASONS. A case opened without any
  # detection reasons still has to be resolvable, so the merge form falls back to
  # 'admin_reviewed' -- it must stay in this vocabulary or every such merge would be rejected.
  OPERATOR_REASON_CODES = %w[admin_reviewed manual_review].freeze

  # Resolution metadata and audit evidence are immutable once written, so the codes that land
  # there are validated against a server-owned vocabulary rather than accepted from the request.
  RESOLUTION_REASON_CODES = (DuplicateReviewCaseCandidate::MATCH_REASONS + OPERATOR_REASON_CODES).freeze

  MAX_REASON_CODES = 20

  belongs_to :subject_user, class_name: 'User', optional: true
  belongs_to :resolved_by, class_name: 'User', optional: true
  has_many :duplicate_review_case_candidates, dependent: :destroy

  enum :status, {
    open: 0,
    resolved_approved: 1,
    resolved_ignored: 2,
    resolved_merged: 3,
    resolved_superseded: 4
  }

  enum :source, {
    registration_soft_match: 0,
    paper_intake: 1,
    admin_create: 2,
    support_claim: 3,
    portal_dependent: 4,
    post_import_reconciliation: 5
  }

  # Identity/linking determination the admin recorded. Distinct from the coarse
  # status enum: it captures what the admin actually decided about the two records.
  enum :resolution_determination, {
    same_person_confirmed: 'same_person_confirmed',
    authorized_relationship_confirmed: 'authorized_relationship_confirmed',
    keep_separate: 'keep_separate',
    superseded_by_merge: 'superseded_by_merge',
    needs_more_information: 'needs_more_information',
    fraud_or_security_review: 'fraud_or_security_review'
  }, validate: { allow_nil: true }

  MERGE_ELIGIBLE_DETERMINATIONS = %w[same_person_confirmed].freeze

  validates :deduplication_key, presence: true
  validates :opened_at, presence: true
  validates :metadata, presence: true
  validate :metadata_shape
  validate :resolution_fields_present_when_resolved
  validate :resolution_metadata_shape
  # Review evidence invariant: a resolved case is terminal and its resolution/snapshot facts
  # are never rewritten. Reads the live database row (not this instance's own dirty
  # tracking) so a caller holding a pre-resolution instance cannot bypass the guard.
  validate :terminal_case_immutable, on: :update
  before_destroy :reject_resolved_case_destroy

  scope :open_cases, -> { where(status: statuses[:open]) }
  scope :resolved_cases, -> { where(status: RESOLVED_STATUSES.map { |s| statuses[s] }) }
  scope :for_subject, ->(user) { where(subject_user: user) }
  scope :for_participant, lambda { |user|
    where(
      '(duplicate_review_cases.subject_user_id = :user_id OR EXISTS (' \
      'SELECT 1 FROM duplicate_review_case_candidates participant_candidates ' \
      'WHERE participant_candidates.duplicate_review_case_id = duplicate_review_cases.id ' \
      'AND participant_candidates.candidate_user_id = :user_id))',
      user_id: user.id
    )
  }

  def open?
    status == 'open'
  end

  def resolved?
    RESOLVED_STATUSES.include?(status)
  end

  def merge_eligible_determination?
    MERGE_ELIGIBLE_DETERMINATIONS.include?(resolution_determination)
  end

  private

  def terminal_case_immutable
    errors.add(:base, 'A resolved duplicate review case cannot be modified') if currently_resolved_in_database?
  end

  def currently_resolved_in_database?
    return false if new_record?

    self.class.unscoped.resolved_cases.exists?(id: id)
  end

  def reject_resolved_case_destroy
    return unless currently_resolved_in_database?

    errors.add(:base, 'A resolved duplicate review case cannot be deleted')
    throw :abort
  end

  def resolution_fields_present_when_resolved
    return unless RESOLVED_STATUSES.include?(status)

    errors.add(:resolution_determination, 'is required to resolve a case') if resolution_determination.blank?
    errors.add(:resolution_rationale, 'is required to resolve a case') if resolution_rationale.blank?
    errors.add(:resolved_by, 'is required to resolve a case') if resolved_by_id.blank?
    errors.add(:resolved_at, 'is required to resolve a case') if resolved_at.blank?
  end

  def resolution_metadata_shape
    return if resolution_metadata.blank?

    unless resolution_metadata.is_a?(Hash)
      errors.add(:resolution_metadata, 'must be a hash')
      return
    end

    unknown_keys = resolution_metadata.keys.map(&:to_s) - ALLOWED_RESOLUTION_METADATA_KEYS
    if unknown_keys.any?
      errors.add(:resolution_metadata, "contains unsupported keys: #{unknown_keys.join(', ')}")
      return
    end

    validate_reason_code_list(:resolution_metadata, resolution_metadata['reason_codes'], RESOLUTION_REASON_CODES)
  end

  def metadata_shape
    return if metadata.blank?

    unknown_keys = metadata.keys.map(&:to_s) - ALLOWED_METADATA_KEYS
    if unknown_keys.any?
      errors.add(:metadata, "contains unsupported keys: #{unknown_keys.join(', ')}")
      return
    end

    # Detection metadata carries only machine-derived match evidence; the operator codes are
    # valid on a resolution, not on the reason a case was opened.
    validate_reason_code_list(:metadata, metadata['reason_codes'], DuplicateReviewCaseCandidate::MATCH_REASONS)
    validate_submitted_contact_digest(metadata['submitted_contact_digest'])
    validate_intake_context(metadata['intake_context'])
    validate_subject_snapshot(metadata['subject_snapshot'])
  end

  def validate_reason_code_list(attribute, reason_codes, allowed_codes)
    return if reason_codes.blank?

    unless reason_codes.is_a?(Array)
      errors.add(attribute, 'reason_codes must be an array')
      return
    end

    if reason_codes.length > MAX_REASON_CODES
      errors.add(attribute, "reason_codes cannot exceed #{MAX_REASON_CODES} entries")
      return
    end

    invalid = reason_codes.map(&:to_s) - allowed_codes
    return if invalid.empty?

    errors.add(attribute, "reason_codes contains unsupported values: #{invalid.join(', ')}")
  end

  def validate_submitted_contact_digest(digest)
    return if digest.blank?
    return if digest.to_s.match?(DuplicateReviewCases::MetadataSanitizer::DIGEST_PATTERN)

    errors.add(:metadata, 'submitted_contact_digest must be a 64-character hex digest')
  end

  def validate_intake_context(context)
    return if context.blank?
    return if DuplicateReviewCases::MetadataSanitizer::ALLOWED_INTAKE_CONTEXTS.include?(context.to_s)

    errors.add(:metadata, 'intake_context is not allowed')
  end

  def validate_subject_snapshot(snapshot)
    return if snapshot.blank?

    unless snapshot.is_a?(Hash)
      errors.add(:metadata, 'subject_snapshot must be a hash')
      return
    end

    unknown_keys = snapshot.keys.map(&:to_s) - DuplicateReviewCases::MetadataSanitizer::ALLOWED_SUBJECT_SNAPSHOT_KEYS
    return if unknown_keys.empty?

    errors.add(:metadata, "subject_snapshot contains unsupported keys: #{unknown_keys.join(', ')}")
  end
end
