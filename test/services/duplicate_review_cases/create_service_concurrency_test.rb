# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  # Focused concurrency evidence for plan section 1's scenarios: "online registration case
  # creation versus selected-case merge/retirement" and "case creation versus the non-merge
  # resolution path that clears the subject flag." Each test forces one specific commit
  # order deterministically.
  #
  # Both sides of every race are the real production services -- including the "holder"
  # side, which is the *winning* transaction, not a copy of its effects. This works because
  # `ActiveRecord::Base.transaction` joins an already-open transaction on the same connection
  # rather than starting a real nested one: wrapping a real service call in an outer
  # `transaction do ... end` lets that service run to completion (locking, requalifying,
  # mutating) while the actual COMMIT is deferred until the outer block returns. Signaling
  # "ready" after the service call returns, then waiting on a release queue before letting
  # the outer block end, holds the winner's locks open under our control without faking any
  # of its logic.
  #
  # The contender is confirmed genuinely blocked at the Postgres level via
  # `wait_until_blocked_on_lock`/`backend_pid` (which polls `pg_blocking_pids` from a
  # dedicated observer connection, not thread-start-order assumptions) before the holder is
  # unconditionally released via `confirm_blocked_then_release`, so a failing or timing-out
  # wait can never leave the holder's lock open and hang cleanup behind it.
  class CreateServiceConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'merge commits first: case creation then fails closed on the now-merged candidate' do
      admin, canonical, duplicate, third_party, review_case = build_fixtures

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
      create_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        create_result = run_create(admin:, duplicate:, third_party:)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert create_result.failure?,
             "expected case creation to fail closed once the candidate was merged: #{create_result.message}"
      assert_match(/no longer an eligible active record/i, create_result.message)
      assert_not DuplicateReviewCase.exists?(subject_user_id: third_party.id)
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate, third_party)
    end

    test 'case creation commits first: merge reloads before blocking the unsupported competing case' do
      admin, canonical, duplicate, third_party, review_case = build_fixtures

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      create_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          create_result = run_create(admin:, duplicate:, third_party:)
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

      assert create_result.success?, "expected case creation (holder) to succeed: #{create_result&.message}"
      assert merge_result.failure?, "expected the merge to fail closed against the new competing case: #{merge_result.message}"
      assert_match(/related records changed while the merge was being prepared/i, merge_result.message)
      assert_not duplicate.reload.merged?

      retry_result = run_merge(admin:, canonical:, duplicate:, review_case:)
      assert retry_result.failure?, 'expected the stable unsupported case to block the merge on retry'
      assert_match(/another open duplicate review case/i, retry_result.message)
      assert_not duplicate.reload.merged?
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate, third_party)
    end

    test 'case creation commits first: clear_flag on the same subject then observes the open case and refuses' do
      subject = create(:constituent, first_name: 'ClearRace', last_name: 'SubjectOne', needs_duplicate_review: false)
      candidate = create(
        :constituent,
        first_name: 'ClearRace',
        last_name: 'CandidateOne',
        email: "cand-#{SecureRandom.hex(3)}@example.com"
      )
      admin = create(:admin)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      create_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          create_result = run_create(admin:, duplicate: candidate, third_party: subject)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      clear_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        clear_result = run_clear_flag(subject:, admin:)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert create_result.success?, "expected case creation (holder) to succeed: #{create_result&.message}"
      assert clear_result.failure?, 'expected clear_flag to refuse once it observed the newly opened case'
      assert_match(/open review case/i, clear_result.message)
      assert subject.reload.needs_duplicate_review, 'the flag must remain set -- the open case still owns it'
      assert_equal 0, Event.where(action: 'duplicate_review_flag_cleared', auditable_id: subject.id, auditable_type: 'User').count,
                   'a refused clear must never emit its audit event'
    ensure
      cleanup_duplicate_review_test_data!(subject, candidate, admin)
    end

    test 'clear_flag commits first: a subsequent case creation on the same subject proceeds normally' do
      subject = create(:constituent, first_name: 'ClearRace', last_name: 'SubjectTwo', needs_duplicate_review: true)
      candidate = create(
        :constituent,
        first_name: 'ClearRace',
        last_name: 'CandidateTwo',
        email: "cand-#{SecureRandom.hex(3)}@example.com"
      )
      admin = create(:admin)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      clear_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          clear_result = run_clear_flag(subject:, admin:)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      create_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        create_result = run_create(admin:, duplicate: candidate, third_party: subject)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert clear_result.success?, "expected clear_flag (holder) to succeed: #{clear_result&.message}"
      assert create_result.success?, "expected case creation to succeed once the flag-clear committed: #{create_result.message}"
      assert subject.reload.needs_duplicate_review, "the new case's own creation must re-set the flag"
      assert_equal 1, Event.where(action: 'duplicate_review_flag_cleared', auditable_id: subject.id, auditable_type: 'User').count,
                   'exactly one clear audit event from the committed clear_flag, never zero or duplicated'
    ensure
      cleanup_duplicate_review_test_data!(subject, candidate, admin)
    end

    private

    def build_fixtures
      admin = create(:admin)
      canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
      duplicate = nil
      begin
        Current.paper_context = true
        duplicate = create(:constituent, email: nil, phone: "555-#{rand(100..999)}-#{rand(1000..9999)}", communication_preference: :letter)
      ensure
        Current.reset
      end
      third_party = create(:constituent, email: "third-#{SecureRandom.hex(3)}@example.com")

      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: duplicate,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['exact_phone'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(candidate_user: canonical, match_reason: 'exact_phone', snapshot: {})

      [admin, canonical, duplicate, third_party, review_case]
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
        contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' },
        delivery_choice: 'canonical'
      ).call
    end

    def run_create(admin:, duplicate:, third_party:)
      CreateService.new(
        source: :registration_soft_match,
        subject_user: User.find(third_party.id),
        actor: User.find(admin.id),
        reason_codes: ['name_dob'],
        candidates: [CreateService::CandidateInput.new(User.find(duplicate.id), 'name_dob', {})]
      ).call
    end

    def run_clear_flag(subject:, admin:)
      ClearFlagService.new(user: User.find(subject.id), actor: User.find(admin.id), rationale: 'attempting during a race').call
    end
  end
end
