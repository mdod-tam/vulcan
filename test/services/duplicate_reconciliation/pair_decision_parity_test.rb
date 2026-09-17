# frozen_string_literal: true

require 'test_helper'

module DuplicateReconciliation
  class PairDecisionParityTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    setup do
      DatabaseCleaner.clean
      @probe = DiscoveryProbe.new(statement_timeout_ms: 5000)
      @baseline_drift = @probe.call.flag_metrics.fetch(:flagged_without_open_case_or_match)
      @admin = create(:admin)
      @users = Array.new(2) { matching_user }
      @first, @second = @users
    end

    teardown do
      cleanup_duplicate_review_test_data!(@admin, @users)
    end

    test 'inline paper accepts either orientation and additional match reasons without becoming merge eligible' do
      [@users, @users.reverse].each do |subject, candidate|
        review_case = record_pair(
          source: :paper_intake, subject: subject, candidates: [candidate],
          context: 'paper_inline_keep_separate', reasons: %w[address_zip name_dob], candidate_reason: 'address_zip'
        )
        assert_nil review_case.strict_post_import_pair_ids
      end

      assert_readers_agree(:confirmed_different, required_users: [])
      assert_equal 0, @probe.call.case_metrics.fetch(:post_import_total)
    end

    test 'post-import decisions retain strict ordering and reason shape' do
      review_case = record_pair(source: :post_import_reconciliation)
      assert_equal @users.map(&:id), review_case.strict_post_import_pair_ids
      assert_readers_agree(:confirmed_different, required_users: [])
      assert_equal 1, @probe.call.case_metrics.fetch(:post_import_strict_shape)
    end

    %i[registration_soft_match portal_dependent paper_intake admin_create support_claim].each do |source|
      test "legacy #{source} keep separate does not adjudicate a reconciliation pair" do
        record_pair(source: source)
        assert_readers_agree(:unreviewed, required_users: @users)
      end
    end

    test 'existing-person selection is not evidence about two persisted people' do
      record_pair(
        source: :paper_intake, subject: nil, context: 'paper_inline_selection',
        status: :resolved_selected, determination: :existing_person_selected
      )
      assert_readers_agree(:unreviewed, required_users: @users)
    end

    test 'paper address-only evidence does not settle a name and DOB pair' do
      record_pair(source: :paper_intake, context: 'paper_inline_keep_separate',
                  reasons: ['address_zip'], candidate_reason: 'address_zip')
      assert_readers_agree(:unreviewed, required_users: @users)
    end

    test 'reversed post-import evidence remains malformed' do
      review_case = record_pair(source: :post_import_reconciliation, subject: @second, candidates: [@first])
      assert_nil review_case.strict_post_import_pair_ids
      assert_readers_agree(:unreviewed, required_users: @users)
      assert_equal 1, @probe.call.case_metrics.fetch(:post_import_malformed)
    end

    test 'post-import evidence with missing reasons or participant cannot suppress a pair' do
      record_pair(source: :post_import_reconciliation, reasons: [])
      record_pair(source: :post_import_reconciliation, subject: nil)
      record_pair(source: :post_import_reconciliation, candidates: [nil])
      record_pair(source: :post_import_reconciliation, candidates: [@first])
      assert_readers_agree(:unreviewed, required_users: @users)
      assert_equal 4, @probe.call.case_metrics.fetch(:post_import_malformed)
    end

    test 'multiple candidate rows including a deleted candidate cannot settle a pair' do
      record_pair(source: :post_import_reconciliation, candidates: [@second, nil])
      record_pair(source: :paper_intake, context: 'paper_inline_keep_separate', candidates: [@second, nil])
      assert_readers_agree(:unreviewed, required_users: @users)
    end

    test 'historical scalar reasons remain malformed rather than being coerced into pair evidence' do
      review_case = record_pair(source: :post_import_reconciliation)
      review_case.update_columns(metadata: { 'reason_codes' => 'name_dob' })
      assert_nil review_case.strict_post_import_pair_ids
      assert_readers_agree(:unreviewed, required_users: @users)
      assert_equal 1, @probe.call.case_metrics.fetch(:post_import_malformed)
    end

    test 'an open post-import case wins over completed paper evidence for the same pair' do
      record_pair(source: :paper_intake, context: 'paper_inline_keep_separate')
      record_pair(source: :post_import_reconciliation, status: :open)
      assert_readers_agree(:open_reconciliation, required_users: @users)
    end

    test 'open cases of other sources keep participant flags independently of pair adjudication' do
      record_pair(source: :paper_intake, context: 'paper_inline_keep_separate')
      record_pair(source: :portal_dependent, candidates: [], status: :open)
      assert_readers_agree(:confirmed_different, required_users: [@first])
    end

    test 'settling one pair does not settle another pair sharing its participants' do
      record_pair(source: :paper_intake, context: 'paper_inline_keep_separate')
      third = matching_user
      @users << third
      assert_readers_agree(:confirmed_different, required_users: @users)
      assert_equal :unreviewed, Population.new.pair_for_ids(@first.id, third.id).state
    end

    test 'superseded pair history is stale rather than unresolved or confirmed different' do
      record_pair(source: :post_import_reconciliation, status: :resolved_superseded, determination: :superseded_by_merge)
      assert_readers_agree(:stale_ineligible, required_users: [])
    end

    test 'locked post-import requalification does not reuse a cached preflight answer' do
      review_case = record_pair(source: :post_import_reconciliation, status: :open)
      candidate_id = review_case.duplicate_review_case_candidates.sole.id
      ApplicationRecord.cache do
        assert_equal @users.map(&:id), review_case.strict_post_import_pair_ids
        on_own_connection do
          DuplicateReviewCaseCandidate.find(candidate_id).update!(match_reason: 'address_zip')
        end.value

        ApplicationRecord.transaction do
          locked_case = DuplicateReviewCase.lock.find(review_case.id)
          locked_case.duplicate_review_case_candidates.lock.to_a
          assert_nil locked_case.strict_post_import_pair_ids
        end
      end
    end

    private

    def matching_user
      create(:constituent, first_name: 'PairParity', last_name: 'Review', date_of_birth: Date.new(1984, 6, 9),
                           status: :active, needs_duplicate_review: true)
    end

    def record_pair(source:, **options)
      candidates = options.fetch(:candidates, [@second])
      status = options.fetch(:status, :resolved_ignored)
      metadata = { 'reason_codes' => options.fetch(:reasons, ['name_dob']) }
      metadata.merge!('intake_context' => options[:context], 'intake_role' => 'self_applicant', 'receipt_digest' => 'b' * 64) if options[:context]
      review_case = DuplicateReviewCase.create!(
        source: source, subject_user: options.fetch(:subject, @first), status: :open,
        subject_fingerprint: options[:context] ? 'a' * 64 : nil,
        deduplication_key: SecureRandom.hex(32), opened_at: Time.current, metadata: metadata
      )
      candidates.each do |candidate|
        review_case.duplicate_review_case_candidates.create!(
          candidate_user: candidate, match_reason: options.fetch(:candidate_reason, 'name_dob'), snapshot: {}
        )
      end
      return review_case if status == :open

      review_case.update!(
        status: status, resolution_determination: options.fetch(:determination, :keep_separate),
        resolution_rationale: 'Historical evidence for the pair contract.', resolved_at: Time.current, resolved_by: @admin,
        resolution_metadata: status == :resolved_selected ? { selected_user_id: candidates.sole.id } : {}
      )
      review_case
    end

    def assert_readers_agree(state, required_users:)
      ids = [@first.id, @second.id].sort
      assert_equal state, Population.new.pair_for_ids(*ids).state
      assert_equal state, Population.new.pairs.find { |pair| pair.ids == ids }.state
      projection = ReviewFlagProjection.new
      @users.each do |user|
        assert_equal required_users.include?(user), projection.required_for?(user), "flag projection for #{user.id}"
      end
      expected_drift = @baseline_drift + (@users - required_users).size
      assert_equal expected_drift, @probe.call.flag_metrics.fetch(:flagged_without_open_case_or_match)
    end
  end
end
