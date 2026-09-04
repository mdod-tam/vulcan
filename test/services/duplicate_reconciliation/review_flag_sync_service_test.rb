# frozen_string_literal: true

require 'test_helper'

module DuplicateReconciliation
  class ReviewFlagSyncServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @date_of_birth = Date.new(1982, 7, 9)
    end

    test 'sets both members of an unresolved pair and is idempotent' do
      first = create_match(needs_duplicate_review: false)
      second = create_match(needs_duplicate_review: false)

      assert_no_difference ['DuplicateReviewCase.count', 'Event.count', 'Notification.count'] do
        first_result = ReviewFlagSyncService.new.call
        second_result = ReviewFlagSyncService.new.call

        assert first_result.success?
        assert second_result.success?
        assert_equal 0, second_result.data[:set_count]
        assert_equal 0, second_result.data[:cleared_count]
      end

      assert first.reload.needs_duplicate_review
      assert second.reload.needs_duplicate_review
    end

    test 'preserves subject and candidate flags from every pre-existing open case source' do
      participants = DuplicateReviewCase.sources.keys.excluding('post_import_reconciliation').flat_map do |source|
        subject = create(
          :constituent,
          first_name: "Source#{source}",
          last_name: "Subject#{SecureRandom.hex(3)}",
          date_of_birth: @date_of_birth,
          needs_duplicate_review: false
        )
        candidate = create(
          :constituent,
          first_name: "Source#{source}",
          last_name: "Candidate#{SecureRandom.hex(3)}",
          date_of_birth: @date_of_birth,
          needs_duplicate_review: false
        )
        review_case = DuplicateReviewCase.create!(
          source: source,
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
        [subject, candidate]
      end

      ReviewFlagSyncService.new.call

      participants.each do |user|
        assert user.reload.needs_duplicate_review
      end
    end

    test 'clears a flag only when no unresolved pair or open case remains' do
      unmatched = create(
        :constituent,
        first_name: 'No',
        last_name: "Match#{SecureRandom.hex(4)}",
        date_of_birth: @date_of_birth,
        needs_duplicate_review: true
      )

      result = ReviewFlagSyncService.new.call

      assert result.success?
      assert_not unmatched.reload.needs_duplicate_review
      assert_operator result.data[:cleared_count], :>=, 1
    end

    test 'durable different-person resolution remains clear on rerun' do
      first = create_match(needs_duplicate_review: true)
      second = create_match(needs_duplicate_review: true)
      resolve_pair_as_different(first, second)

      ReviewFlagSyncService.new.call
      first_result = first.reload.needs_duplicate_review
      second_result = second.reload.needs_duplicate_review
      ReviewFlagSyncService.new.call

      assert_not first_result
      assert_not second_result
      assert_not first.reload.needs_duplicate_review
      assert_not second.reload.needs_duplicate_review
    end

    test 'resolving one pair does not clear a participant with another unresolved pair' do
      first, second, third = Array.new(3) { create_match(needs_duplicate_review: true) }
      resolve_pair_as_different(first, second)

      ReviewFlagSyncService.new.call

      assert first.reload.needs_duplicate_review
      assert second.reload.needs_duplicate_review
      assert third.reload.needs_duplicate_review
      assert Population.new.pair_for_ids(first.id, third.id).unresolved?
    end

    private

    def create_match(needs_duplicate_review:)
      create(
        :constituent,
        first_name: 'Flag',
        last_name: 'Projection',
        date_of_birth: @date_of_birth,
        email: "flag-#{SecureRandom.hex(5)}@example.com",
        phone: nil,
        phone_type: nil,
        needs_duplicate_review: needs_duplicate_review
      )
    end

    def resolve_pair_as_different(first, second)
      subject, candidate = [first, second].sort_by(&:id)
      create_result = DuplicateReviewCases::CreateService.new(
        source: :post_import_reconciliation,
        subject_user: subject,
        actor: @admin,
        reason_codes: ['name_dob'],
        candidates: [DuplicateReviewCases::CreateService::CandidateInput.new(candidate, 'name_dob', {})]
      ).call
      review_case = create_result.data.fetch(:duplicate_review_case)
      review_case.update!(
        status: :resolved_ignored,
        resolution_determination: :keep_separate,
        resolution_rationale: 'confirmed different people',
        resolved_by: @admin,
        resolved_at: Time.current
      )
    end
  end
end
