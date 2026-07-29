# frozen_string_literal: true

require 'test_helper'

class DuplicateReviewCaseTest < ActiveSupport::TestCase
  setup do
    @subject = create(:constituent)
    @candidate = create(:constituent)
    @admin = create(:admin)
    @review_case = DuplicateReviewCase.create!(
      source: :registration_soft_match,
      subject_user: @subject,
      deduplication_key: SecureRandom.hex(16),
      metadata: { 'reason_codes' => ['exact_phone'] },
      opened_at: Time.current,
      status: :open
    )
    @candidate_record = @review_case.duplicate_review_case_candidates.create!(
      candidate_user: @candidate, match_reason: 'exact_phone', snapshot: {}
    )
  end

  test 'an open case can be resolved' do
    assert @review_case.update(
      status: :resolved_ignored,
      resolution_determination: :keep_separate,
      resolution_rationale: 'confirmed different people',
      resolved_by: @admin,
      resolved_at: Time.current
    )
  end

  test 'a resolved case is terminal and cannot be modified further, even from a stale pre-resolution instance' do
    stale = DuplicateReviewCase.find(@review_case.id)

    resolve_review_case!

    assert_not stale.update(resolution_rationale: 'changed my mind')
    assert_includes stale.errors[:base], 'A resolved duplicate review case cannot be modified'
  end

  test 'a resolved case cannot be destroyed' do
    resolve_review_case!

    assert_not @review_case.destroy
    assert DuplicateReviewCase.exists?(@review_case.id)
  end

  test 'an open case can still be destroyed, cascading its candidates' do
    assert @review_case.destroy
    assert_not DuplicateReviewCase.exists?(@review_case.id)
    assert_not DuplicateReviewCaseCandidate.exists?(@candidate_record.id)
  end

  test 'a candidate cannot be modified once its case is resolved' do
    resolve_review_case!

    assert_not @candidate_record.update(match_reason: 'name_dob')
    assert_includes @candidate_record.errors[:base], 'Cannot create or modify a candidate once its duplicate review case is resolved'
  end

  test 'a new candidate cannot be created on an already-resolved case' do
    resolve_review_case!
    other_user = create(:constituent)

    new_candidate = @review_case.duplicate_review_case_candidates.new(candidate_user: other_user, match_reason: 'name_dob', snapshot: {})

    assert_not new_candidate.save
    assert_includes new_candidate.errors[:base], 'Cannot create or modify a candidate once its duplicate review case is resolved'
  end

  test 'a candidate cannot be destroyed once its case is resolved' do
    resolve_review_case!

    assert_not @candidate_record.destroy
    assert DuplicateReviewCaseCandidate.exists?(@candidate_record.id)
  end

  test 'a candidate on an open case can still be modified or destroyed' do
    assert @candidate_record.update(match_reason: 'name_dob')
    assert @candidate_record.destroy
  end

  private

  def resolve_review_case!
    @review_case.update!(
      status: :resolved_ignored,
      resolution_determination: :keep_separate,
      resolution_rationale: 'confirmed different people',
      resolved_by: @admin,
      resolved_at: Time.current
    )
  end
end
