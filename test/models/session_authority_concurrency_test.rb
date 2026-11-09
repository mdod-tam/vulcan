# frozen_string_literal: true

require 'test_helper'

class SessionAuthorityConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ConcurrencyTestHelper

  %i[rotation request].each do |first|
    test "#{first} takes the user lock first when a loaded bearer races reauthentication" do
      user = create(:constituent)
      record = user.sessions.create!(ip_address: '127.0.0.1', user_agent: 'Rotation race')
      token = record.session_token
      stale = Session.find(record.id)
      ready = Queue.new
      release = Queue.new
      holder_pid_queue = Queue.new
      contender_pid_queue = Queue.new
      request_result = nil

      holder = on_own_connection do
        holder_pid_queue << backend_pid
        User.transaction do
          locked = User.lock_for_merge_integrity!(user).fetch(user.id)
          if first == :rotation
            Session.find(record.id).rotate_after_authentication!(user: locked)
          else
            stale.require_live!(token: token, user: locked)
            request_result = :accepted
          end
          ready << true
          release.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
      wait_for_signal(ready, thread: holder)

      contender = on_own_connection do
        contender_pid_queue << backend_pid
        User.transaction do
          locked = User.lock_for_merge_integrity!(user).fetch(user.id)
          if first == :rotation
            begin
              stale.require_live!(token: token, user: locked)
              request_result = :accepted
            rescue Session::AuthenticationRequired
              request_result = :refused
            end
          else
            Session.find(record.id).rotate_after_authentication!(user: locked)
          end
        end
      end
      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender),
        holder_pid: holder_pid, release_queue: release, holder_thread: holder, contender_thread: contender
      )

      assert_equal(first == :rotation ? :refused : :accepted, request_result)
      assert_nil Session.for_token(token).take, 'rotation must invalidate the original bearer after either ordering'
      assert_equal [record.id], user.sessions.pluck(:id), 'rotation preserves the pending operation session binding'
    ensure
      cleanup_duplicate_review_test_data!(user)
    end
  end
end
