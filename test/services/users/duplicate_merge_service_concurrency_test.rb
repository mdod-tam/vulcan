# frozen_string_literal: true

require 'test_helper'

module Users
  # Focused concurrency evidence for the merge boundary itself (plan section 2): two admins
  # racing to merge the same open case must serialize through
  # User.lock_for_merge_integrity!, and exactly one of them must win -- the other fails
  # closed with zero partial side effects rather than double-merging or corrupting the
  # winner's result. Both threads run the identical, unordered attempt so the test proves
  # the invariant regardless of which admin's request happens to reach Postgres first.
  class DuplicateMergeServiceConcurrencyTest < ActiveSupport::TestCase
    # Rails' fixture-connection-sharing patch (on by default) hands every thread the same
    # underlying connection for the life of a transactional test, which would make a single
    # Postgres session appear to "lock against itself" instead of producing real contention.
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'two concurrent merge attempts on the same case: exactly one succeeds, the other fails closed' do
      admin = create(:admin)
      canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
      duplicate = nil
      begin
        Current.paper_context = true
        duplicate = create(:constituent, email: nil, phone: '555-777-8888', communication_preference: :letter)
      ensure
        Current.reset
      end

      # Only a registration_soft_match case is eligible for the merge path (plan acceptance
      # criteria); a support_claim/paper_intake/admin_create case must fail static preflight.
      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: duplicate,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['exact_phone'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(candidate_user: canonical, match_reason: 'exact_phone', snapshot: {})

      attempt = lambda do
        Users::DuplicateMergeService.new(
          actor: User.find(admin.id),
          duplicate_review_case: DuplicateReviewCase.find(review_case.id),
          canonical_user: User.find(canonical.id),
          duplicate_user: User.find(duplicate.id),
          same_person_confirmed: true,
          rationale: 'confirmed same person via support call',
          reason_codes: %w[exact_phone],
          contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' },
          delivery_choice: 'canonical'
        ).call
      end

      result_a = nil
      result_b = nil

      # Each thread writes only to its own outer variable, so there is no shared mutable
      # state between them beyond the real Postgres row locks under test. Thread#join
      # re-raises automatically if the service raised instead of returning a Result, so
      # neither thread can wedge the test in an unjoinable state.
      thread_a = on_own_connection { result_a = attempt.call }
      thread_b = on_own_connection { result_b = attempt.call }

      thread_a.join
      thread_b.join

      results = [result_a, result_b]
      successes = results.select(&:success?)
      failures = results.select(&:failure?)

      assert_equal 1, successes.size, "expected exactly one merge to succeed: #{results.map(&:message)}"
      assert_equal 1, failures.size, "expected exactly one merge to fail closed: #{results.map(&:message)}"

      duplicate.reload
      canonical.reload
      review_case.reload

      assert duplicate.merged?, 'duplicate must end up merged exactly once'
      assert_equal canonical.id, duplicate.merged_into_user_id
      assert_equal 'resolved_merged', review_case.status
      assert_equal 1, Event.where(action: 'duplicate_user_merged', auditable_id: canonical.id, auditable_type: 'User').count,
                   'exactly one merge audit event, never a partial second merge'
      assert_equal '555-777-8888', canonical.phone
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    test 'a merge attempt physically blocks on User.lock_for_merge_integrity! itself, not merely on the case row' do
      admin = create(:admin)
      canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
      duplicate = nil
      begin
        Current.paper_context = true
        duplicate = create(:constituent, email: nil, phone: '555-666-9999', communication_preference: :letter)
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
      review_case.duplicate_review_case_candidates.create!(candidate_user: canonical, match_reason: 'exact_phone', snapshot: {})

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new

      # Thread A locks ONLY the base User rows via the shared primitive -- it never touches
      # duplicate_review_cases at all. If User.lock_for_merge_integrity! were removed (or
      # replaced with a no-op), the contender below would sail through immediately instead
      # of genuinely blocking, and wait_until_blocked_on_lock would time out and fail this
      # test -- proving the User-row lock itself, not incidental case-row serialization, is
      # what provides the exclusion.
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          User.lock_for_merge_integrity!(admin.id, canonical.id, duplicate.id)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      contender_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        contender_result = Users::DuplicateMergeService.new(
          actor: User.find(admin.id),
          duplicate_review_case: DuplicateReviewCase.find(review_case.id),
          canonical_user: User.find(canonical.id),
          duplicate_user: User.find(duplicate.id),
          same_person_confirmed: true,
          rationale: 'confirmed same person via support call',
          reason_codes: %w[exact_phone],
          contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' },
          delivery_choice: 'canonical'
        ).call
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert contender_result.success?, "expected the unblocked merge to succeed: #{contender_result.message}"
      assert duplicate.reload.merged?
      assert_equal canonical.id, duplicate.merged_into_user_id
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end
  end
end
