# frozen_string_literal: true

class DuplicateReviewCase < ApplicationRecord
  ALLOWED_METADATA_KEYS = %w[
    reason_codes
    submitted_contact_digest
    intake_context
    subject_snapshot
  ].freeze

  # Structured record of the latest admin review transition. Stores decision context
  # and codes only; never raw contact values (those come from live records at merge time).
  ALLOWED_REVIEW_METADATA_KEYS = %w[
    reason_codes
    canonical_user_id
    merged_user_id
    contact_choices
    delivery_choice
    transfer_summary
    merge_audit_event_id
  ].freeze

  PENDING_STATUSES = %w[open awaiting_information security_review].freeze
  NONTERMINAL_HOLD_STATUSES = %w[awaiting_information security_review].freeze
  TERMINAL_STATUSES = %w[resolved_keep_separate resolved_relationship resolved_merged].freeze

  belongs_to :subject_user, class_name: 'User', optional: true
  belongs_to :reviewed_by, class_name: 'User', optional: true
  belongs_to :resolved_by, class_name: 'User', optional: true
  has_many :duplicate_review_case_candidates, dependent: :destroy

  enum :status, {
    open: 0,
    awaiting_information: 1,
    security_review: 2,
    resolved_keep_separate: 3,
    resolved_relationship: 4,
    resolved_merged: 5
  }, validate: true

  enum :source, {
    registration_soft_match: 0,
    paper_intake: 1,
    admin_create: 2,
    support_claim: 3,
    portal_dependent: 4
  }

  validates :deduplication_key, presence: true
  validates :opened_at, presence: true
  validates :metadata, presence: true
  validate :metadata_shape
  validate :review_fields_match_status
  validate :review_metadata_shape

  scope :pending_review, -> { where(status: statuses.values_at(*PENDING_STATUSES)) }
  scope :active_queue, -> { pending_review }
  scope :resolved_cases, -> { where(status: statuses.values_at(*TERMINAL_STATUSES)) }
  scope :for_subject, ->(user) { where(subject_user: user) }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def pending?
    PENDING_STATUSES.include?(status)
  end

  def owns_duplicate_review_flag?
    pending?
  end

  def merge_allowed?
    open?
  end

  def active_queue?
    pending?
  end

  def nonterminal_hold?
    NONTERMINAL_HOLD_STATUSES.include?(status)
  end

  def supported_relationship_persisted?
    subject_id = subject_user_id
    candidate_ids = duplicate_review_case_candidates.where.not(candidate_user_id: nil).distinct.pluck(:candidate_user_id)
    return false if subject_id.blank? || candidate_ids.empty?

    GuardianRelationship.where(guardian_id: subject_id, dependent_id: candidate_ids)
                        .or(GuardianRelationship.where(guardian_id: candidate_ids, dependent_id: subject_id))
                        .exists?
  end

  private

  def review_fields_match_status
    if terminal? || nonterminal_hold?
      errors.add(:review_rationale, 'is required for a review outcome') if review_rationale.blank?
      errors.add(:reviewed_by, 'is required for a review outcome') if reviewed_by_id.blank?
      errors.add(:reviewed_at, 'is required for a review outcome') if reviewed_at.blank?
    end

    if terminal?
      errors.add(:resolved_by, 'is required to resolve a case') if resolved_by_id.blank?
      errors.add(:resolved_at, 'is required to resolve a case') if resolved_at.blank?
    elsif resolved_by_id.present? || resolved_at.present?
      errors.add(:base, 'pending cases cannot have terminal resolution fields')
    end
  end

  def review_metadata_shape
    return if review_metadata.blank?

    unless review_metadata.is_a?(Hash)
      errors.add(:review_metadata, 'must be a hash')
      return
    end

    unknown_keys = review_metadata.keys.map(&:to_s) - ALLOWED_REVIEW_METADATA_KEYS
    return if unknown_keys.empty?

    errors.add(:review_metadata, "contains unsupported keys: #{unknown_keys.join(', ')}")
  end

  def metadata_shape
    return if metadata.blank?

    unknown_keys = metadata.keys.map(&:to_s) - ALLOWED_METADATA_KEYS
    if unknown_keys.any?
      errors.add(:metadata, "contains unsupported keys: #{unknown_keys.join(', ')}")
      return
    end

    validate_reason_codes(metadata['reason_codes'])
    validate_submitted_contact_digest(metadata['submitted_contact_digest'])
    validate_intake_context(metadata['intake_context'])
    validate_subject_snapshot(metadata['subject_snapshot'])
  end

  def validate_reason_codes(reason_codes)
    return if reason_codes.blank?

    unless reason_codes.is_a?(Array)
      errors.add(:metadata, 'reason_codes must be an array')
      return
    end

    invalid = reason_codes.map(&:to_s) - DuplicateReviewCaseCandidate::MATCH_REASONS
    return if invalid.empty?

    errors.add(:metadata, "reason_codes contains unsupported values: #{invalid.join(', ')}")
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
