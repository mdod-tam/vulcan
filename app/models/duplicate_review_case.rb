# frozen_string_literal: true

class DuplicateReviewCase < ApplicationRecord
  ALLOWED_METADATA_KEYS = %w[
    reason_codes
    submitted_contact_digest
    intake_context
    subject_snapshot
  ].freeze

  belongs_to :subject_user, class_name: 'User', optional: true
  belongs_to :resolved_by, class_name: 'User', optional: true
  has_many :duplicate_review_case_candidates, dependent: :destroy

  enum :status, {
    open: 0,
    resolved_approved: 1,
    resolved_ignored: 2,
    resolved_merged: 3
  }

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

  scope :open_cases, -> { where(status: statuses[:open]) }
  scope :for_subject, ->(user) { where(subject_user: user) }

  def open?
    status == 'open'
  end

  private

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
