# frozen_string_literal: true

require 'test_helper'
require Rails.root.join('db/migrate/20260917004500_add_inline_paper_review_outcomes')

module DuplicateReviewCases
  class PaperIntakeTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @candidate = create(:constituent, first_name: 'Robin', last_name: 'Review', date_of_birth: Date.new(1980, 2, 3))
      @attrs = @candidate.attributes.symbolize_keys.slice(:first_name, :last_name, :date_of_birth, :city, :state, :zip_code)
      @preview = Applications::PaperIdentityReview.new(constituent_params: @attrs, admin: @admin).call
    end

    test 'keep separate resolves the actual pair and is visible to reconciliation' do
      review = decision(determination: 'keep_separate')
      assert review.confirmed?
      subject = create(:constituent, **@attrs)

      cases = record(review, subject)
      review_case = cases.sole
      assert review_case.resolved_ignored?
      assert_equal 'keep_separate', review_case.resolution_determination
      assert_equal @admin, review_case.resolved_by
      assert_equal [@candidate.id], review_case.duplicate_review_case_candidates.pluck(:candidate_user_id)
      assert_equal :confirmed_different, DuplicateReconciliation::Population.new.pair_for_ids(subject.id, @candidate.id).state
      assert_not subject.reload.needs_duplicate_review?
      assert_equal 1, Event.where(action: 'duplicate_review_case_resolved').where("metadata->>'duplicate_review_case_id' = ?", review_case.id.to_s).count
      assert_equal 0, Event.where(action: 'paper_identity_no_match_confirmed').count
    end

    test 'existing selection stores proposed identity without a second user or merge' do
      review = decision(selected_candidate_id: @candidate.id)
      assert review.selected?

      assert_no_difference 'User.count' do
        review_case = record(review, @candidate).sole
        assert review_case.resolved_selected?
        assert_nil review_case.subject_user_id
        assert_match(/\A[a-f0-9]{64}\z/, review_case.subject_fingerprint)
        assert_equal @candidate.id, review_case.resolution_metadata['selected_user_id']
        assert_not @candidate.reload.merged?
        assert_not review_case.update(resolution_rationale: 'Rewrite')
      end
    end

    test 'rollback is explicitly refused without changing schema or recorded selections' do
      review_case = record(decision(selected_candidate_id: @candidate.id), @candidate).sole
      connection = ActiveRecord::Base.connection
      constraints = connection.check_constraints(:duplicate_review_cases)

      assert_raises(ActiveRecord::IrreversibleMigration) { AddInlinePaperReviewOutcomes.new.down }

      assert review_case.reload.resolved_selected?
      assert_equal constraints, connection.check_constraints(:duplicate_review_cases)
      assert connection.index_exists?(:duplicate_review_cases, :deduplication_key,
                                      name: 'index_inline_paper_review_decisions_unique', unique: true)
    end

    test 'replaying a completed selection returns the same case without a second audit' do
      review = decision(selected_candidate_id: @candidate.id)
      first = record(review, @candidate).sole
      assert_no_difference ['DuplicateReviewCase.count', 'Event.count'] do
        assert_equal first, record(review, @candidate).sole
      end
    end

    test 'decision and candidate evidence roll back with the business transaction' do
      review = decision(determination: 'keep_separate')
      assert_no_difference ['User.count', 'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
        ActiveRecord::Base.transaction(requires_new: true) do
          subject = create(:constituent, **@attrs)
          record(review, subject)
          raise ActiveRecord::Rollback
        end
      end
    end

    test 'changed facts and missing explicit determination cannot authorize creation' do
      assert_not decision.confirmed?
      assert_not decision(determination: 'keep_separate', attrs: @attrs.merge(city: 'Changed')).confirmed?
      travel 31.minutes do
        assert_not decision(determination: 'keep_separate').confirmed?
      end
    end

    test 'paper decisions accept inactive unmerged applicants without requiring portal access' do
      @candidate.update!(status: :inactive)
      @preview = Applications::PaperIdentityReview.new(constituent_params: @attrs, admin: @admin).call
      selected = decision(selected_candidate_id: @candidate.id)
      assert selected.selected?
      assert record(selected, @candidate).sole.resolved_selected?
      separate = decision(determination: 'keep_separate')
      subject = create(:constituent, **@attrs, status: :inactive)
      assert record(separate, subject).sole.resolved_ignored?
    end

    private

    def decision(attrs: @attrs, **choice)
      Applications::PaperIdentityReview.new(
        constituent_params: attrs, admin: @admin, submitted_token: @preview.token, **choice
      ).call
    end

    def record(review, user)
      CreateService.record_paper_decision!(review: review, user: user, actor: @admin,
                                           rationale: 'Staff compared the paper identity with the record.', receipt: @preview.token)
    end
  end
end
