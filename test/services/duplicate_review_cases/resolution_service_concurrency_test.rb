# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  # ResolutionService and DuplicateMergeService both act on the selected review case and
  # subject. These tests exercise both production owners in both commit orders and prove the
  # shared base-User-first ordering before either service locks the case row.
  class ResolutionServiceConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'merge commits first: non-merge resolution fails closed without a second audit' do
      admin, canonical, duplicate, review_case = build_fixtures

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      merge_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          merge_result = run_merge(admin:, canonical:, duplicate:, review_case:)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      resolution_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        resolution_result = run_resolution(admin:, review_case:)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, merge_result.message
      assert resolution_result.failure?
      assert_match(/no longer open/i, resolution_result.message)
      assert_equal 'resolved_merged', review_case.reload.status
      assert duplicate.reload.merged?
      assert_equal 1, Event.where(action: 'duplicate_user_merged', auditable: canonical).count
      assert_equal 0, Event.where(action: 'duplicate_review_case_resolved', auditable: duplicate).count
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    test 'non-merge resolution commits first: merge fails closed without retirement or merge audit' do
      admin, canonical, duplicate, review_case = build_fixtures

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      resolution_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          resolution_result = run_resolution(admin:, review_case:)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      merge_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        merge_result = run_merge(admin:, canonical:, duplicate:, review_case:)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert resolution_result.success?, resolution_result.message
      assert merge_result.failure?
      assert_match(/no longer open/i, merge_result.message)
      assert_equal 'resolved_ignored', review_case.reload.status
      assert_not duplicate.reload.merged?
      assert_equal 1, Event.where(action: 'duplicate_review_case_resolved', auditable: duplicate).count
      assert_equal 0, Event.where(action: 'duplicate_user_merged', auditable: canonical).count
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    private

    def build_fixtures
      admin = create(:admin)
      canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
      duplicate = nil
      begin
        Current.paper_context = true
        duplicate = create(
          :constituent,
          email: nil,
          phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
          communication_preference: :letter
        )
      ensure
        Current.reset
      end

      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: duplicate,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['exact_phone'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(
        candidate_user: canonical,
        match_reason: 'exact_phone',
        snapshot: {}
      )

      [admin, canonical, duplicate, review_case]
    end

    def run_merge(admin:, canonical:, duplicate:, review_case:)
      Users::DuplicateMergeService.new(
        actor: User.find(admin.id),
        duplicate_review_case: DuplicateReviewCase.find(review_case.id),
        canonical_user: User.find(canonical.id),
        duplicate_user: User.find(duplicate.id),
        same_person_confirmed: true,
        rationale: 'confirmed same person via support call',
        reason_codes: %w[exact_phone],
        contact_choices: {
          phone: 'duplicate',
          phone_type: 'voice',
          email: 'canonical',
          address: 'canonical'
        },
        delivery_choice: 'canonical'
      ).call
    end

    def run_resolution(admin:, review_case:)
      ResolutionService.new(
        duplicate_review_case: DuplicateReviewCase.find(review_case.id),
        actor: User.find(admin.id),
        rationale: 'records verified as separate people',
        reason_codes: %w[manual_review]
      ).call
    end
  end
end
