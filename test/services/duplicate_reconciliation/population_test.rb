# frozen_string_literal: true

require 'test_helper'

module DuplicateReconciliation
  class PopulationTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @date_of_birth = Date.new(1985, 4, 12)
    end

    test 'groups case-insensitive names by deterministically encrypted date of birth' do
      first = create_match(first_name: 'Case', last_name: 'Sensitive')
      second = create_match(first_name: 'cASE', last_name: 'sENSITIVE')
      create_match(first_name: 'Case', last_name: 'Sensitive', date_of_birth: Date.new(1985, 4, 13))

      pairs = Population.new.pairs
      matching_pair_count = pairs.count { |pair| pair.ids.intersect?([first.id, second.id]) }

      assert_includes pairs.map(&:ids), [first.id, second.id].sort
      assert_equal 1, matching_pair_count
    end

    test 'derives every stable unordered pair once for a three-member group' do
      users = Array.new(3) { create_match }
      expected = users.map(&:id).sort.combination(2).to_a

      actual = Population.new.pairs.map(&:ids).select { |ids| (ids - users.map(&:id)).empty? }
      repeated = Population.new.pairs.map(&:ids).select { |ids| (ids - users.map(&:id)).empty? }

      assert_equal expected, actual
      assert_equal actual, repeated
    end

    test 'finds unflagged records whose writes bypassed callbacks' do
      first = create_match
      second = create_match
      Users::Constituent.where(id: [first.id, second.id]).update_all(needs_duplicate_review: false)

      pair = Population.new.pair_for_ids(second.id, first.id)

      assert_equal [first.id, second.id].sort, pair.ids
      assert_equal :unreviewed, pair.state
      assert_not pair.first.needs_duplicate_review
      assert_not pair.second.needs_duplicate_review
    end

    test 'does not advertise stored date groups that cannot pass logical DOB requalification' do
      first = create_match
      second = create_match
      demo_ids = [first.id, second.id]
      Users::Constituent.where(id: demo_ids).update_all(
        date_of_birth: Arel.sql("'not-a-logical-date'")
      )

      pair_ids = Population.new.pairs.map(&:ids)

      assert_not_includes pair_ids, demo_ids.sort
      assert_nil Population.new.pair_for_ids(*demo_ids)
    end

    test 'summarizes applications with one bounded status query instead of eager loading records' do
      first, second, third = Array.new(3) { create_match }
      create(:application, :approved, user: first)
      create(:application, user: second, status: :draft)
      create(:application, :approved, user: third)
      create(:application, user: third, status: :in_progress)
      application_queries = []
      subscriber = lambda do |*, payload|
        application_queries << payload[:sql] if payload[:sql].match?(/FROM "applications"/)
      end

      pairs = ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        Population.new.pairs
      end
      members = pairs.flat_map { |pair| [pair.first, pair.second] }.index_by(&:id)

      assert_equal 'approved-only', members.fetch(first.id).application_summary
      assert_equal 'none', members.fetch(second.id).application_summary
      assert_equal 'active', members.fetch(third.id).application_summary
      assert_equal 1, application_queries.size
      assert_includes application_queries.first, '"applications"."user_id"'
      assert_includes application_queries.first, '"applications"."status"'
      assert_not_includes application_queries.first, '"applications".*'
    end

    test 'resolved keep separate case suppresses only its exact pair' do
      first, second, third = Array.new(3) { create_match }
      review_case = open_pair_case(first, second)
      review_case.update!(
        status: :resolved_ignored,
        resolution_determination: :keep_separate,
        resolution_rationale: 'confirmed different people',
        resolved_by: @admin,
        resolved_at: Time.current
      )

      states = Population.new.pairs.index_by(&:ids).transform_values(&:state)

      assert_equal :confirmed_different, states.fetch([first.id, second.id].sort)
      assert_equal :unreviewed, states.fetch([first.id, third.id].sort)
      assert_equal :unreviewed, states.fetch([second.id, third.id].sort)
    end

    test 'reversed ids resolve to the same canonical pair case' do
      first = create_match
      second = create_match
      review_case = open_pair_case(first, second)

      forward = Population.new.pair_for_ids(first.id, second.id)
      reversed = Population.new.pair_for_ids(second.id, first.id)

      assert_equal forward.ids, reversed.ids
      assert_equal review_case.id, forward.review_case_id
      assert_equal review_case.id, reversed.review_case_id
    end

    test 'multi-candidate cases are not accepted as pair decisions' do
      first, second, third = Array.new(3) { create_match }
      review_case = open_pair_case(first, second)
      review_case.duplicate_review_case_candidates.create!(
        candidate_user: third,
        match_reason: 'name_dob',
        snapshot: {}
      )
      review_case.update!(
        status: :resolved_ignored,
        resolution_determination: :keep_separate,
        resolution_rationale: 'ambiguous group decision',
        resolved_by: @admin,
        resolved_at: Time.current
      )

      states = Population.new.pairs.index_by(&:ids).transform_values(&:state)

      assert_equal :unreviewed, states.fetch([first.id, second.id].sort)
      assert_equal :unreviewed, states.fetch([first.id, third.id].sort)
    end

    test 'retired pair is historical context and not unresolved work' do
      first = create_match
      second = create_match
      review_case = open_pair_case(first, second)
      second.update!(
        status: :inactive,
        merged_into_user: first,
        merged_by: @admin,
        merged_at: Time.current,
        needs_duplicate_review: false
      )
      review_case.update!(
        status: :resolved_merged,
        resolution_determination: :same_person_confirmed,
        resolution_rationale: 'confirmed same person',
        resolved_by: @admin,
        resolved_at: Time.current
      )

      current_pairs = Population.new.pairs
      historical = Population.new.pairs(include_historical: true)

      assert_not_includes current_pairs.map(&:ids), [first.id, second.id].sort
      pair = historical.find { |candidate| candidate.ids == [first.id, second.id].sort }
      assert_equal :merged_retired, pair.state
      assert_not pair.unresolved?
    end

    private

    def create_match(first_name: 'Import', last_name: 'Duplicate', date_of_birth: @date_of_birth)
      create(
        :constituent,
        first_name: first_name,
        last_name: last_name,
        date_of_birth: date_of_birth,
        email: "duplicate-#{SecureRandom.hex(5)}@example.com",
        phone: nil,
        phone_type: nil,
        communication_preference: :email
      )
    end

    def open_pair_case(first, second)
      subject, candidate = [first, second].sort_by(&:id)
      result = DuplicateReviewCases::CreateService.new(
        source: :post_import_reconciliation,
        subject_user: subject,
        actor: @admin,
        reason_codes: ['name_dob'],
        candidates: [
          DuplicateReviewCases::CreateService::CandidateInput.new(candidate, 'name_dob', {})
        ]
      ).call
      assert result.success?, result.message
      result.data.fetch(:duplicate_review_case)
    end
  end
end
