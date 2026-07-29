# frozen_string_literal: true

# Deterministic multi-connection concurrency helpers for the PR4b merge-integrity boundary
# tests. Real row-lock contention only exists across two genuinely separate Postgres
# sessions, so every scenario spins up its own thread with its own checked-out connection
# rather than faking contention with in-process mutexes.
#
# Includers must run inside a test class that commits its setup data (see
# +run_with_real_commits+) so a second connection can actually see it.
require 'English'
module ConcurrencyTestHelper
  # ActiveSupport::TestCase wraps each test in a DatabaseCleaner :transaction strategy so
  # setup data never touches disk. That's invisible to a second Postgres connection, which
  # would make every "real lock" concurrency test fail for the wrong reason (RecordNotFound,
  # not a lock timeout). Roll that transaction back at setup so this test's writes commit
  # normally (plain autocommit, no wrapping transaction of our own).
  #
  # Cleanup deliberately does NOT use DatabaseCleaner's table-wide truncate/delete
  # strategies: `users` is FK-referenced by reference/seed tables that are loaded once per
  # worker and never re-seeded per test (e.g. email_templates.updated_by_id), so a
  # table-wide truncate either fails outright on that live FK or -- with CASCADE -- silently
  # wipes those seed rows for the rest of the run. Each test must instead delete exactly the
  # rows it created, in dependency order, via `cleanup_duplicate_review_test_data!` below.
  def self.included(base)
    base.class_eval do
      setup do
        ConcurrencyTestHelper.warm_connection_pool!
        DatabaseCleaner.clean
        # Rails' query cache is active on the main test thread's own connection throughout
        # the test body (it's wrapped by ActiveSupport::Executor). A verification read late
        # in a test that repeats an earlier identical query for the same row (e.g. a second
        # `User.find(id)` after some setup-time `User.find(id)` earlier in the same test) can
        # silently return the cached pre-race result instead of the real, freshly-committed
        # state written by another thread's connection in between -- proving nothing while
        # looking like a passing assertion. #reload always bypasses the cache and remains
        # safe; disabling the cache here removes the trap for any verification read that
        # doesn't use it.
        ActiveRecord::Base.connection.disable_query_cache!
      end
    end
  end

  # ActiveRecord builds its PostgreSQL type map the first time each physical connection
  # object is actually used, via a `pg_type` introspection query. A barrier test spins up
  # several fresh threads via `on_own_connection`, each checking out whatever connection
  # object the pool hands it; if that happens to be one this process has never used before,
  # the type-map query runs inline with the thread's real work. Touching every pool
  # connection once, before any timed test body runs, pays that specific cost up front
  # instead of mid-test. Runs at most once per process (module-level memoized, not per test
  # class).
  def self.warm_connection_pool!
    return if @pool_warmed

    @pool_warmed = true
    pool = ActiveRecord::Base.connection_pool
    pool.size.times.map { Thread.new { pool.with_connection { |c| c.execute('SELECT 1') } } }.each(&:join)
  end

  # Deletes exactly the duplicate-review/merge fixtures a test created, in FK-safe order, via
  # callback-free bulk deletes (irrelevant to tearing down fixtures, and would otherwise trip
  # the merged-record immutability guard on a retired duplicate). Scoped to the given users'
  # ids, so it never touches any other row -- including any global reference/seed data.
  # Extend this if a future scenario also commits rows in other tables (applications,
  # guardian_relationships, secure_request_forms, recovery_requests, sessions already
  # included below).
  def cleanup_duplicate_review_test_data!(*users)
    ids = users.flatten.compact.map(&:id).uniq
    return if ids.empty?

    case_ids = DuplicateReviewCase.where('subject_user_id IN (?) OR resolved_by_id IN (?)', ids, ids).pluck(:id)
    DuplicateReviewCaseCandidate.where(duplicate_review_case_id: case_ids).delete_all
    DuplicateReviewCaseCandidate.where(candidate_user_id: ids).delete_all
    DuplicateReviewCase.where(id: case_ids).delete_all
    # #destroy_all (not delete_all): applications have dependent: :destroy children
    # (proof_reviews, notifications, secure_request_forms, etc.) with real FK constraints,
    # so a raw bulk delete of the applications row itself would violate those FKs.
    # PrintQueueItem is deleted explicitly first: it has an application_id FK, but Application
    # declares no reverse has_many for it, so #destroy_all's association-cascade never reaches
    # it and the FK would otherwise block the application delete.
    application_ids = Application.where('user_id IN (?) OR managing_guardian_id IN (?)', ids, ids).pluck(:id)
    PrintQueueItem.where(application_id: application_ids).delete_all
    Application.where(id: application_ids).destroy_all
    # Notification.recipient_id/actor_id and RecoveryRequest.user_id/resolved_by_id both FK
    # to users with no reverse has_many on User, so -- like PrintQueueItem above -- nothing
    # cascades into them automatically; deleted explicitly before the user rows themselves.
    Notification.where('recipient_id IN (?) OR actor_id IN (?)', ids, ids).delete_all
    RecoveryRequest.where('user_id IN (?) OR resolved_by_id IN (?)', ids, ids).delete_all
    GuardianRelationship.where('guardian_id IN (?) OR dependent_id IN (?)', ids, ids).delete_all
    Event.where('user_id IN (?) OR (auditable_type = ? AND auditable_id IN (?))', ids, 'User', ids).delete_all
    Session.where(user_id: ids).delete_all
    User.unscoped.where(id: ids).delete_all
  end

  # Runs +block+ on its own thread with its own checked-out AR connection, so it sees a real
  # Postgres session distinct from the main test thread/connection.
  def on_own_connection(&)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&)
    end
  end

  # Blocks the calling thread until PostgreSQL confirms `pid` is genuinely blocked
  # specifically *by* `blocked_by` (not just blocked by something), or raises after
  # `timeout` seconds.
  #
  # Polls `pg_blocking_pids(pid)` -- which reads the lock manager's actual wait-for graph --
  # rather than `pg_stat_activity.wait_event_type`. This harness found the latter unreliable
  # under load: `wait_event_type` reflects a coarse, momentary classification of what the
  # backend is doing, and repeated `pg_stat_activity` polling from a busy connection can
  # observe a false negative during a real, sustained lock wait (confirmed by a timing
  # capture showing the polled contender's own `.call` blocking for ~3s -- matching the
  # timeout -- then succeeding immediately once released, i.e. genuinely blocked the whole
  # time; the poll just never saw it). `pg_blocking_pids` is queried directly against the
  # lock manager and does not have that failure mode.
  #
  # Checking that `blocked_by` specifically appears in the blocking-pid list (not just that
  # the list is non-empty) proves the barrier is testing what it claims to: that *this*
  # holder, not some incidental third session, is what the contender is waiting on.
  #
  # Runs the poll on its own dedicated thread/connection (never the calling thread's own
  # connection, which could be busy or itself checked out for other setup work), verifies up
  # front that this dedicated connection isn't sitting inside a lingering open transaction of
  # its own (which would make its snapshot of the lock graph stale), and explicitly disables
  # the query cache for the poll -- a cached first answer would otherwise never change no
  # matter how many times the loop re-polls.
  def wait_until_blocked_on_lock(pid, blocked_by:, timeout: 10, thread: nil)
    safe_pid = Integer(pid)
    expected_blocker = Integer(blocked_by)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    outcome = nil
    error = nil

    observer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        if conn.transaction_open?
          error = RuntimeError.new('Observer connection unexpectedly has an open transaction')
          next
        end

        conn.uncached do
          loop do
            if thread && !thread.alive?
              begin
                thread.join # re-raises if it died with an exception
              rescue StandardError => e
                error = e
                break
              end
              error = RuntimeError.new("Backend pid #{safe_pid}'s thread finished without ever blocking on a lock")
              break
            end

            blocking_pids = parse_pg_int_array(conn.select_value("SELECT pg_blocking_pids(#{safe_pid})::text"))
            if blocking_pids.include?(expected_blocker)
              outcome = true
              break
            end

            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              error = RuntimeError.new(
                "Timed out waiting for backend pid #{safe_pid} to be blocked specifically by pid " \
                "#{expected_blocker} (last observed blockers: #{blocking_pids.inspect})"
              )
              break
            end

            poll_pace
          end
        end
      end
    end
    reap_thread(observer, timeout: timeout + 5, suppress_errors: false)

    raise error if error

    outcome
  end

  # Parses a PostgreSQL integer-array text literal (e.g. "{123,456}" or "{}") into a Ruby
  # Array of Integers. Plain integers need no quote/escape handling.
  def parse_pg_int_array(text)
    return [] if text.blank?

    text.delete('{}').split(',').compact_blank.map(&:to_i)
  end

  def backend_pid
    ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
  end

  # Bounded `queue.pop`: fails fast (instead of hanging forever) if `thread` dies before ever
  # pushing a value, or if nothing arrives within `timeout` seconds. A plain blocking `.pop`
  # here would hang the whole suite if the producing thread never reaches its push -- e.g. it
  # raised before signaling readiness.
  def wait_for_signal(queue, thread: nil, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return queue.pop(true)
    rescue ThreadError
      if thread && !thread.alive?
        thread.join # re-raises the thread's own exception if it died abnormally
        raise 'Thread finished without ever signaling on the queue'
      end
      raise 'Timed out waiting for a signal on the queue' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      poll_pace
    end
  end

  # A brief, bounded pause between iterations of an otherwise condition-based poll loop
  # (never used to "guess" a duration -- the loop above still re-checks the real condition
  # immediately after). Plain `Thread.pass` gives no minimum yield and lets a tight loop fire
  # a fresh round-trip as fast as the scheduler allows, which under GVL/OS contention can
  # itself starve the very thread being polled for. A tiny sleep forces a real yield instead.
  def poll_pace
    sleep 0.005
  end

  # Confirms `contender_pid` is genuinely Postgres-blocked (via wait_until_blocked_on_lock),
  # then *unconditionally* releases the holder and reaps both threads (bounded, and killed
  # outright if still alive after that bound), regardless of whether the wait itself times
  # out or raises. Without this guarantee, a failing or timing-out barrier test leaves the
  # holder's transaction -- and its row locks -- open forever, hanging any later cleanup (or
  # the rest of the suite) that touches the same rows; and `Thread#join(timeout)` alone is
  # not sufficient, since it returns `nil` rather than raising when the thread is still
  # alive, so a naive `rescue` around it never actually catches a wedged thread.
  #
  # If the wait succeeds normally, a reap-time exception from either thread (e.g. the
  # contender's own work raised after unblocking) is allowed to propagate as a real test
  # failure. If the wait itself failed, reap-time exceptions are swallowed instead of
  # shadowing the original (more informative) failure.
  def confirm_blocked_then_release(contender_pid, holder_pid:, release_queue:, holder_thread:, contender_thread:, timeout: 10)
    wait_until_blocked_on_lock(contender_pid, blocked_by: holder_pid, timeout: timeout, thread: contender_thread)
  ensure
    already_failing = !$ERROR_INFO.nil?
    release_queue << true

    # Reaping is attempted for BOTH threads unconditionally, even if reaping the first one
    # raises: an `each` that let a reap exception propagate immediately would skip the second
    # thread's reap entirely, leaving its transaction -- and row lock -- open, which is
    # exactly the hang this helper exists to prevent. Only the first reap error (if any) is
    # re-raised, after both reaps have been attempted.
    first_reap_error = nil
    [holder_thread, contender_thread].each do |t|
      reap_thread(t, timeout: timeout, suppress_errors: already_failing)
    rescue StandardError => e
      first_reap_error ||= e
    end
    raise first_reap_error if first_reap_error
  end

  # Waits up to `timeout` seconds for `thread` to finish and re-raises its exception, if any.
  # `Thread#join(timeout)` returns `nil` (rather than raising) when the thread is still alive
  # after the bound, so that alone can't detect a wedged thread; this checks for exactly that
  # and kills the thread outright rather than letting it survive as an orphan competing for
  # GVL/connection resources with later tests. A thread killed mid-transaction still runs its
  # `ensure`-based rollback as the kill unwinds, so its lock is released either way.
  def reap_thread(thread, timeout:, suppress_errors:)
    finished = thread.join(timeout)
    return if finished

    thread.kill
    killed_finished = thread.join(timeout) # bounded chance for the kill's unwind (rollback, etc.) to complete
    return if killed_finished || suppress_errors

    raise "Thread #{thread.inspect} would not die even after #kill and a #{timeout}s bounded join; " \
          'it may still be holding a Postgres lock as an orphan'
  rescue StandardError
    raise unless suppress_errors
  end
end
