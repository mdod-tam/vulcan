# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class DeduplicationKeyTest < ActiveSupport::TestCase
    test 'normalizes reason and candidate ordering while retaining candidate multiplicity' do
      first = DeduplicationKey.call(
        source: :support_claim,
        subject_user_id: 10,
        reason_codes: %w[name_dob exact_phone],
        candidate_user_ids: [30, 20, 30]
      )
      second = DeduplicationKey.call(
        source: 'support_claim',
        subject_user_id: 10,
        reason_codes: %w[exact_phone name_dob],
        candidate_user_ids: [30, 30, 20]
      )
      without_duplicate_candidate = DeduplicationKey.call(
        source: :support_claim,
        subject_user_id: 10,
        reason_codes: %w[exact_phone name_dob],
        candidate_user_ids: [30, 20]
      )

      assert_equal first, second
      assert_not_equal first, without_duplicate_candidate
    end
  end
end
