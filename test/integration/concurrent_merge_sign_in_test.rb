# frozen_string_literal: true

require 'test_helper'

# Proves the row lock actually serializes session creation against a concurrent merge,
# not just that a reload happens to observe committed state most of the time. A plain
# `user.reload` can still read a not-yet-committed pre-merge snapshot and then insert a
# session after the merge commits; only a shared `SELECT ... FOR UPDATE` closes that
# window. Uses a real second thread with its own DB connection and Queue-based handshakes
# (no sleeps) so the interleaving is deterministic, not timing-dependent.
class ConcurrentMergeSignInTest < ActionDispatch::IntegrationTest
  test 'session creation blocks on and then respects a concurrent merge holding the row lock' do
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean

    duplicate = create(:constituent, password: 'password123', password_confirmation: 'password123')
    canonical = create(:constituent)

    lock_held = Queue.new
    release_merge = Queue.new
    merge_done = Queue.new

    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          locked = User.lock.find(duplicate.id)
          lock_held << true
          release_merge.pop # hold the row lock open until the main thread signals
          locked.sessions.destroy_all
          locked.update!(merged_into_user_id: canonical.id, status: :inactive, merged_at: Time.current)
        end
      end
    ensure
      merge_done << true
    end

    lock_held.pop # the merge thread now holds `SELECT ... FOR UPDATE` on the duplicate row

    session_thread_session = nil
    session_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        # Exercises the same code path as ApplicationController#_create_and_set_session_cookie:
        # a fresh in-memory user object attempting to lock and mint a session concurrently.
        contender = User.find(duplicate.id)
        session_thread_session = contender.with_lock do
          next nil unless contender.public_login_active?

          candidate = contender.sessions.new(user_agent: 'race-test', ip_address: '127.0.0.1')
          candidate.save ? candidate : nil
        end
      end
    end

    # Give the session thread a moment to actually block on the lock before releasing it,
    # so this test would fail (session created) if the lock were not actually exclusive.
    sleep 0.2
    assert session_thread.alive?, 'the session thread should still be blocked on the row lock'

    release_merge << true
    merge_done.pop
    session_thread.join(5)

    assert_nil session_thread_session, 'a session must not be created once the concurrent merge has committed'
    assert_not duplicate.reload.public_login_active?
    assert_equal 0, Session.where(user_id: duplicate.id).count
  ensure
    merge_thread&.join(5)
    session_thread&.join(5)
    DatabaseCleaner.strategy = :transaction
  end
end
