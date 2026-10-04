# frozen_string_literal: true

# Real PostgreSQL row-lock contention requires separate connections.
# Setup data must commit so the other connection can read it.
require 'English'
module ConcurrencyTestHelper
  # Setup ends DatabaseCleaner's transaction so later writes commit.
  # Another connection cannot read uncommitted setup data.
  #
  # Table-wide cleanup can violate foreign keys to users or remove shared seed rows
  # such as email_templates.updated_by_id. Delete test rows in dependency order
  # with cleanup_duplicate_review_test_data! instead.
  def self.included(base)
    base.class_eval do
      setup do
        ConcurrencyTestHelper.warm_connection_pool!
        DatabaseCleaner.clean
        # Without a query cache, verification reads can see commits from other connections.
        # Repeated User.find calls can otherwise return state from before the race.
        # User#reload bypasses the cache.
        ActiveRecord::Base.connection.disable_query_cache!
      end
    end
  end

  # The warmup runs queries before timed barriers to reduce PostgreSQL type-map setup.
  # A connection's first query can include pg_type introspection.
  # This warmup runs at most once per process.
  def self.warm_connection_pool!
    return if @pool_warmed

    @pool_warmed = true
    pool = ActiveRecord::Base.connection_pool
    pool.size.times.map { Thread.new { pool.with_connection { |c| c.execute('SELECT 1') } } }.each(&:join)
  end

  # Bulk deletes bypass the immutability guard on retired duplicates.
  # Deletes use the supplied user IDs to avoid table-wide cleanup.
  # Extend this cleanup when a scenario commits rows in another table.
  def cleanup_duplicate_review_test_data!(*users)
    ids = users.flatten.compact.map(&:id).uniq
    return if ids.empty?

    case_ids = DuplicateReviewCase.where('subject_user_id IN (?) OR resolved_by_id IN (?)', ids, ids).pluck(:id)
    DuplicateReviewCaseCandidate.where(duplicate_review_case_id: case_ids).delete_all
    DuplicateReviewCaseCandidate.where(candidate_user_id: ids).delete_all
    DuplicateReviewCase.where(id: case_ids).delete_all
    # Application#destroy_all removes dependent children before their foreign keys can block deletion.
    # PrintQueueItem comes first because Application has no reverse association for it.
    application_ids = Application.where('user_id IN (?) OR managing_guardian_id IN (?)', ids, ids).pluck(:id)
    PrintQueueItem.where(application_id: application_ids).delete_all
    Application.where(id: application_ids).destroy_all
    # Explicit deletion covers actor_id and resolved_by_id references before the user rows.
    Notification.where('recipient_id IN (?) OR actor_id IN (?)', ids, ids).delete_all
    RecoveryRequest.where('user_id IN (?) OR resolved_by_id IN (?)', ids, ids).delete_all
    GuardianRelationship.where('guardian_id IN (?) OR dependent_id IN (?)', ids, ids).delete_all
    Event.where('user_id IN (?) OR (auditable_type = ? AND auditable_id IN (?))', ids, 'User', ids).delete_all
    Session.where(user_id: ids).delete_all
    User.unscoped.where(id: ids).delete_all
  end

  # +block+ runs on a separate thread with a connection from the pool.
  def on_own_connection(&)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&)
    end
  end

  # The wait ends when pg_blocking_pids identifies blocked_by as the blocker for pid.
  # It raises after timeout seconds. The exact blocker excludes unrelated lock waits.
  #
  # A prior timing capture showed a three-second lock wait that pg_stat_activity.wait_event_type polling missed.
  # pg_blocking_pids queries the lock manager instead.
  #
  # A separate observer connection rejects open transactions and uses uncached queries.
  # A cached result would not reflect later changes to the lock graph.
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
                thread.join # A failed thread propagates its exception here.
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

  # PostgreSQL integer arrays need no quote or escape handling.
  # Examples: "{123,456}" and "{}".
  def parse_pg_int_array(text)
    return [] if text.blank?

    text.delete('{}').split(',').compact_blank.map(&:to_i)
  end

  def backend_pid
    ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
  end

  # The timeout bounds queue.pop if a producer fails before its push.
  # An empty queue also raises after the producer exits.
  def wait_for_signal(queue, thread: nil, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return queue.pop(true)
    rescue ThreadError
      if thread && !thread.alive?
        thread.join # A failed thread propagates its exception here.
        raise 'Thread finished without ever signaling on the queue'
      end
      raise 'Timed out waiting for a signal on the queue' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      poll_pace
    end
  end

  # The pause gives the producer time to run under scheduler contention.
  # Thread.pass provides no minimum pause. Each loop tests its condition again after this sleep.
  def poll_pace
    sleep 0.005
  end

  # The ensure block releases the holder and reaps both threads even if the wait fails.
  # Otherwise, an open transaction can retain row locks and hang later cleanup.
  #
  # Reap errors propagate after a successful wait. If the wait fails, that original
  # error takes precedence over a reap error.
  def confirm_blocked_then_release(contender_pid, holder_pid:, release_queue:, holder_thread:, contender_thread:, timeout: 10)
    wait_until_blocked_on_lock(contender_pid, blocked_by: holder_pid, timeout: timeout, thread: contender_thread)
  ensure
    already_failing = !$ERROR_INFO.nil?
    release_queue << true

    # Both reaps precede propagation of the first error. An immediate raise
    # after the first reap would leave the other thread and its locks alive.
    first_reap_error = nil
    [holder_thread, contender_thread].each do |t|
      reap_thread(t, timeout: timeout, suppress_errors: already_failing)
    rescue StandardError => e
      first_reap_error ||= e
    end
    raise first_reap_error if first_reap_error
  end

  # The helper kills a thread that remains alive after timeout seconds.
  # Thread#join returns nil at the deadline instead of raising.
  # A killed thread can run transaction cleanup as it unwinds. The second join uses the same timeout.
  # Thread exceptions propagate unless suppress_errors is true.
  def reap_thread(thread, timeout:, suppress_errors:)
    finished = thread.join(timeout)
    return if finished

    thread.kill
    killed_finished = thread.join(timeout) # Transaction cleanup gets a second bounded wait.
    return if killed_finished || suppress_errors

    raise "Thread #{thread.inspect} would not die even after #kill and a #{timeout}s bounded join; " \
          'it may still be holding a Postgres lock as an orphan'
  rescue StandardError
    raise unless suppress_errors
  end
end
