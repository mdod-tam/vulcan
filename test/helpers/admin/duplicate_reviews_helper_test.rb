# frozen_string_literal: true

require 'test_helper'

module Admin
  class DuplicateReviewsHelperTest < ActionView::TestCase
    test 'candidate review badge links to the open case it participates in' do
      subject = create(:constituent)
      candidate = create(:constituent)
      review_case = DuplicateReviewCase.create!(
        source: :portal_dependent,
        subject_user: subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(
        candidate_user: candidate,
        match_reason: 'name_dob',
        snapshot: {}
      )

      assert_equal admin_duplicate_review_path(review_case), admin_duplicate_review_entry_path(candidate)
    end
  end
end
