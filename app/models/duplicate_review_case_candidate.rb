# frozen_string_literal: true

class DuplicateReviewCaseCandidate < ApplicationRecord
  ALLOWED_SNAPSHOT_KEYS = %w[
    contact_digest
    last_four
    email_backed_public_portal_account
    real_email
    real_phone
  ].freeze

  MATCH_REASONS = %w[
    exact_email
    exact_email_non_portal
    exact_phone
    email_phone_split
    name_dob
    address_zip
    address_only_record
  ].freeze

  belongs_to :duplicate_review_case
  belongs_to :candidate_user, class_name: 'User', optional: true

  validates :match_reason, presence: true, inclusion: { in: MATCH_REASONS }
  validate :snapshot_shape
  # Review evidence invariant: candidate snapshots are never created or rewritten once the
  # parent case is resolved (terminal) -- runs on :create too, not just :update, since a new
  # candidate added to an already-resolved case would be just as much a rewrite of terminal
  # evidence as editing an existing one. Reads the live database state of the parent case,
  # not an in-memory association, so a stale case instance cannot bypass the guard. This is
  # a best-effort backstop (an unlocked read), not full concurrency control -- no live
  # caller mutates an existing candidate outside of case-open time, so there is no traced
  # writer for this to serialize against yet.
  validate :immutable_once_case_resolved, on: %i[create update]
  before_destroy :reject_destroy_once_case_resolved

  private

  def immutable_once_case_resolved
    return unless case_currently_resolved?

    errors.add(:base, 'Cannot create or modify a candidate once its duplicate review case is resolved')
  end

  def reject_destroy_once_case_resolved
    return unless case_currently_resolved?

    errors.add(:base, 'Cannot delete a candidate once its duplicate review case is resolved')
    throw :abort
  end

  def case_currently_resolved?
    DuplicateReviewCase.unscoped.resolved_cases.exists?(id: duplicate_review_case_id)
  end

  def snapshot_shape
    return if snapshot.blank?

    unknown_keys = snapshot.keys.map(&:to_s) - ALLOWED_SNAPSHOT_KEYS
    if unknown_keys.any?
      errors.add(:snapshot, "contains unsupported keys: #{unknown_keys.join(', ')}")
      return
    end

    return unless DuplicateReviewCases::CandidateSnapshotSanitizer.invalid_snapshot_values?(snapshot)

    errors.add(:snapshot, 'contains unsupported or raw contact values')
  end
end
