# frozen_string_literal: true

require 'test_helper'

module DuplicateReconciliation
  class ReviewPairServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @first = create_match
      @second = create_match
    end

    test 'creates one canonical pair-scoped non-gating case and flags both records' do
      result = nil
      assert_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count',
                         'Event.where(action: \'duplicate_review_case_opened\').count'], 1 do
        assert_no_difference 'Notification.count' do
          result = review(@first.id, @second.id)
        end
      end

      assert result.success?, result.message
      review_case = result.data.fetch(:duplicate_review_case)
      expected_subject, expected_candidate = [@first, @second].sort_by(&:id)
      assert_equal 'post_import_reconciliation', review_case.source
      assert_equal expected_subject.id, review_case.subject_user_id
      assert_equal [expected_candidate.id], review_case.duplicate_review_case_candidates.pluck(:candidate_user_id)
      assert_equal ['name_dob'], review_case.metadata['reason_codes']
      assert @first.reload.needs_duplicate_review
      assert @second.reload.needs_duplicate_review
      assert_not Application.identity_review_pending_for?(@first)
      assert_not Application.identity_review_pending_for?(@second)
      assert_equal @first, User.find_by_login_identifier(@first.email)
      assert_equal @second, User.find_by_login_identifier(@second.email)
    end

    test 'reversed requests reuse exactly one open case' do
      first_result = review(@first.id, @second.id)

      assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
        second_result = review(@second.id, @first.id)

        assert second_result.success?, second_result.message
        assert second_result.data.fetch(:idempotent)
        assert_equal first_result.data.fetch(:duplicate_review_case).id,
                     second_result.data.fetch(:duplicate_review_case).id
      end
    end

    test 'forged non-matching ids create no case flag or audit' do
      outsider = create(
        :constituent,
        first_name: 'Not',
        last_name: 'Matching',
        date_of_birth: Date.new(1999, 1, 2),
        needs_duplicate_review: false
      )

      assert_no_review_side_effects(@first, outsider) do
        result = review(@first.id, outsider.id)

        assert result.failure?
        assert_match(/no longer form a current supported/i, result.message)
      end
    end

    test 'stale pair creates no case after matching facts change' do
      @second.update!(last_name: 'Changed')

      assert_no_review_side_effects(@first, @second) do
        result = review(@first.id, @second.id)

        assert result.failure?
      end
    end

    test 'merged or inactive participant creates no case' do
      survivor = create(:constituent)
      @second.update!(status: :inactive, merged_into_user: survivor, merged_at: Time.current)

      assert_no_review_side_effects(@first, @second) do
        result = review(@first.id, @second.id)

        assert result.failure?
        assert_match(/active, eligible constituents/i, result.message)
      end
    end

    test 'resolved pair cannot be reopened' do
      review_case = review(@first.id, @second.id).data.fetch(:duplicate_review_case)
      review_case.update!(
        status: :resolved_ignored,
        resolution_determination: :keep_separate,
        resolution_rationale: 'different people',
        resolved_by: @admin,
        resolved_at: Time.current
      )

      assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
        result = review(@second.id, @first.id)

        assert result.failure?
        assert_match(/already been resolved/i, result.message)
      end
    end

    test 'requires an active admin actor' do
      result = ReviewPairService.new(
        actor: create(:constituent),
        first_user_id: @first.id,
        second_user_id: @second.id
      ).call

      assert result.failure?
      assert_equal 0, DuplicateReviewCase.where(source: :post_import_reconciliation).count
    end

    private

    def create_match
      create(
        :constituent,
        first_name: 'Review',
        last_name: 'Pair',
        date_of_birth: Date.new(1987, 8, 21),
        email: "review-pair-#{SecureRandom.hex(5)}@example.com",
        needs_duplicate_review: false
      )
    end

    def review(first_id, second_id)
      ReviewPairService.new(
        actor: @admin,
        first_user_id: first_id,
        second_user_id: second_id
      ).call
    end

    def assert_no_review_side_effects(*users, &block)
      before_flags = users.to_h { |user| [user.id, user.reload.needs_duplicate_review?] }
      assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
        block.call
      end
      users.each do |user|
        assert_equal before_flags.fetch(user.id), user.reload.needs_duplicate_review?
      end
    end
  end
end
