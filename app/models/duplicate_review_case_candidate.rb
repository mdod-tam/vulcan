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

  private

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
