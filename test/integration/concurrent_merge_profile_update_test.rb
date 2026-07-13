# frozen_string_literal: true

require 'test_helper'

class ConcurrentMergeProfileUpdateTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test 'profile endpoint rejects a user retired after authentication loaded stale state' do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean

    duplicate = create(:constituent)
    canonical = create(:constituent)
    original_name = duplicate.first_name
    lock_held = Queue.new
    release_merge = Queue.new
    update_status = nil
    merge_error = nil
    update_error = nil

    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          locked = User.lock.find(duplicate.id)
          lock_held << true
          raise 'timed out waiting to release merge' unless release_merge.pop(timeout: 5)

          locked.update_columns(
            email: nil,
            phone: nil,
            status: User.statuses[:inactive],
            merged_into_user_id: canonical.id,
            merged_at: Time.current,
            updated_at: Time.current
          )
        end
      end
    rescue StandardError => e
      merge_error = e
    end

    assert lock_held.pop(timeout: 5), 'merge did not acquire the duplicate user lock'
    update_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        patch profile_path,
              params: { user: { first_name: 'Stale Update', email: 'restored@example.com' } },
              headers: { 'X-Test-User-Id' => duplicate.id.to_s }
        update_status = response.status
      end
    rescue StandardError => e
      update_error = e
    end

    sleep 0.2
    assert update_thread.alive?, 'profile update should wait for the merge user-row lock'
    release_merge << true
    assert merge_thread.join(5), 'merge thread did not finish'
    assert update_thread.join(5), 'profile update thread did not finish'

    assert_nil merge_error, merge_error&.full_message
    assert_nil update_error, update_error&.full_message
    assert_equal 422, update_status
    duplicate.reload
    assert_equal original_name, duplicate.first_name
    assert_nil duplicate.email
    assert duplicate.merged?
  ensure
    release_merge << true if defined?(release_merge) && release_merge.empty?
    merge_thread&.join(5)
    update_thread&.join(5)
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :transaction
  end
end
