# frozen_string_literal: true

module DuplicateReviewCases
  class CandidateSnapshotSanitizer
    ALLOWED_KEYS = DuplicateReviewCaseCandidate::ALLOWED_SNAPSHOT_KEYS
    BOOLEAN_KEYS = %w[email_backed_public_portal_account real_email real_phone].freeze
    LAST_FOUR_PATTERN = /\A\d{4}\z/

    def self.sanitize(raw)
      return {} if raw.blank?

      snapshot = raw.with_indifferent_access.slice(*ALLOWED_KEYS)
      sanitized = {}
      sanitized['contact_digest'] = sanitize_digest(snapshot[:contact_digest]) if snapshot.key?(:contact_digest)
      sanitized['last_four'] = sanitize_last_four(snapshot[:last_four]) if snapshot.key?(:last_four)

      BOOLEAN_KEYS.each do |key|
        next unless snapshot.key?(key)

        boolean_value = sanitize_boolean(snapshot[key])
        sanitized[key] = boolean_value unless boolean_value.nil?
      end

      sanitized.compact
    end

    def self.invalid_snapshot_values?(raw)
      return false if raw.blank?

      snapshot = raw.with_indifferent_access
      unknown_keys = snapshot.keys.map(&:to_s) - ALLOWED_KEYS
      return true if unknown_keys.any?

      snapshot.slice(*ALLOWED_KEYS).any? do |key, value|
        invalid_snapshot_value?(key.to_s, value)
      end
    end

    def self.invalid_snapshot_value?(key, value)
      case key
      when 'contact_digest'
        value.present? && sanitize_digest(value).nil?
      when 'last_four'
        value.present? && sanitize_last_four(value).nil?
      when *BOOLEAN_KEYS
        !value.nil? && sanitize_boolean(value).nil?
      else
        true
      end
    end
    private_class_method :invalid_snapshot_value?

    def self.sanitize_digest(value)
      MetadataSanitizer.sanitize_digest(value)
    end

    def self.sanitize_last_four(value)
      normalized = value.to_s.strip
      return normalized if normalized.match?(LAST_FOUR_PATTERN)

      nil
    end

    def self.sanitize_boolean(value)
      return value if value.in?([true, false])

      nil
    end
  end
end
