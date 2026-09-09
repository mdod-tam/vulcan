# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class ClearFlagServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @user = create(:constituent, needs_duplicate_review: true)
    end

    test 'clears the flag and logs an audit event' do
      result = nil
      assert_difference 'Event.where(action: \'duplicate_review_flag_cleared\').count', 1 do
        result = ClearFlagService.new(user: @user, actor: @admin, rationale: 'reviewed manually').call
      end

      assert result.success?, result.message
      assert_not @user.reload.needs_duplicate_review
    end

    test 'requires a rationale' do
      result = ClearFlagService.new(user: @user, actor: @admin, rationale: '').call

      assert result.failure?
      assert @user.reload.needs_duplicate_review
    end

    test 'refuses while an open case exists for the subject' do
      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: @user,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      other = create(:constituent, email: "other-#{SecureRandom.hex(3)}@example.com")
      review_case.duplicate_review_case_candidates.create!(candidate_user: other, match_reason: 'name_dob', snapshot: {})

      result = ClearFlagService.new(user: @user, actor: @admin, rationale: 'trying anyway').call

      assert result.failure?
      assert_match(/open review case/i, result.message)
      assert @user.reload.needs_duplicate_review
    end

    test 'refuses while the user is a candidate in an open case' do
      subject = create(:constituent)
      review_case = DuplicateReviewCase.create!(
        source: :support_claim,
        subject_user: subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(
        candidate_user: @user,
        match_reason: 'name_dob',
        snapshot: {}
      )

      result = ClearFlagService.new(user: @user, actor: @admin, rationale: 'trying anyway').call

      assert result.failure?
      assert_match(/open review case/i, result.message)
      assert @user.reload.needs_duplicate_review
    end

    test 'refuses while a current unresolved pair exists' do
      @user.update!(
        first_name: 'Legacy',
        last_name: 'MatchingPair',
        date_of_birth: Date.new(1983, 5, 6)
      )
      create(
        :constituent,
        first_name: 'legacy',
        last_name: 'matchingpair',
        date_of_birth: Date.new(1983, 5, 6)
      )

      assert_no_difference 'Event.where(action: \'duplicate_review_flag_cleared\').count' do
        result = ClearFlagService.new(user: @user, actor: @admin, rationale: 'trying to bypass the pair').call

        assert result.failure?
        assert_match(/unresolved matching pair/i, result.message)
      end
      assert @user.reload.needs_duplicate_review
    end

    # The review-round finding this regresses: a lock does not validate a stale decision. If
    # the user became merged (or otherwise ineligible) while this request waited for the
    # lock, `locked_user.update!` would trip the merged-record immutability guard and raise
    # ActiveRecord::RecordInvalid as an *uncaught* exception -- a 500 -- instead of the clean
    # failure result every other blocker in this service returns.
    test 'fails closed with a result, not an exception, when the user became merged under lock' do
      canonical = create(:constituent, email: "canonical-#{SecureRandom.hex(3)}@example.com")
      @user.update!(merged_into_user: canonical, merged_at: Time.current, status: :inactive)

      result = nil
      assert_no_difference 'Event.where(action: \'duplicate_review_flag_cleared\').count' do
        assert_nothing_raised do
          result = ClearFlagService.new(user: @user, actor: @admin, rationale: 'attempting on a merged user').call
        end
      end

      assert result.failure?, 'expected a failure result, not a raised exception'
      assert_match(/no longer an eligible active record/i, result.message)
      assert @user.reload.needs_duplicate_review, 'the flag must remain unchanged'
    end

    test 'fails closed with a result when the user is suspended' do
      @user.update!(status: :suspended)

      result = ClearFlagService.new(user: @user, actor: @admin, rationale: 'attempting on a suspended user').call

      assert result.failure?
      assert_match(/no longer an eligible active record/i, result.message)
      assert @user.reload.needs_duplicate_review
    end
  end
end
