# frozen_string_literal: true

module DuplicateReviewCases
  # Stable builder for the semantic identity of pending duplicate-review work.
  # Candidate IDs intentionally retain multiplicity because one candidate may carry
  # multiple match-reason rows and CreateService has always included each input row.
  class DeduplicationKey
    def self.call(source:, subject_user_id:, reason_codes:, candidate_user_ids:)
      normalized_reasons = Array(reason_codes).map(&:to_s).sort.join(',')
      normalized_candidates = Array(candidate_user_ids).compact.map(&:to_i).sort.join(',')

      Digest::SHA256.hexdigest(
        [source.to_s, subject_user_id, normalized_reasons, normalized_candidates].join(':')
      )
    end
  end
end
