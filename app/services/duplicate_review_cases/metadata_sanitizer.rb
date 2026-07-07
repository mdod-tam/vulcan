# frozen_string_literal: true

module DuplicateReviewCases
  class MetadataSanitizer
    ALLOWED_SUBJECT_SNAPSHOT_KEYS = %w[contact_digest name_dob_digest].freeze
    ALLOWED_INTAKE_CONTEXTS = %w[registration portal_dependent paper_intake admin_create support_claim].freeze
    DIGEST_PATTERN = /\A[a-f0-9]{64}\z/i

    def self.build(reason_codes:, submitted_contact_digest: nil, intake_context: nil, subject_snapshot: nil)
      {
        reason_codes: Array(reason_codes).map(&:to_s).sort,
        submitted_contact_digest: sanitize_digest(submitted_contact_digest),
        intake_context: sanitize_intake_context(intake_context),
        subject_snapshot: sanitize_subject_snapshot(subject_snapshot)
      }.compact
    end

    def self.sanitize_subject_snapshot(raw)
      return nil if raw.blank?

      snapshot = raw.with_indifferent_access.slice(*ALLOWED_SUBJECT_SNAPSHOT_KEYS)
      sanitized = snapshot.transform_values { |value| sanitize_digest(value) }.compact
      sanitized.presence
    end

    def self.sanitize_digest(value)
      normalized = value.to_s.strip
      return nil if normalized.blank?
      return normalized if normalized.match?(DIGEST_PATTERN)

      nil
    end

    def self.sanitize_intake_context(value)
      normalized = value.to_s.strip
      return nil if normalized.blank?
      return normalized if ALLOWED_INTAKE_CONTEXTS.include?(normalized)

      nil
    end
  end
end
