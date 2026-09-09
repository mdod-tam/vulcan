# frozen_string_literal: true

require 'test_helper'

module Applications
  class GuardianDependentManagementServiceConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'relationship creation waits for retirement and refuses to link the retired guardian' do
      guardian = create(:constituent)
      survivor = create(:constituent)
      dependent = create(:constituent)
      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new

      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          locked_users = User.lock_for_merge_integrity!(guardian.id, survivor.id, dependent.id)
          holder_ready << true
          release_holder.pop
          locked_users.fetch(guardian.id).update!(
            status: :inactive,
            merged_into_user: locked_users.fetch(survivor.id),
            merged_at: Time.current
          )
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      relationship_created = nil
      service_errors = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        service = GuardianDependentManagementService.new(
          {},
          guardian_user: User.find(guardian.id),
          dependent_user: User.find(dependent.id)
        )
        relationship_created = service.create_guardian_relationship('Parent')
        service_errors = service.errors.dup
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:,
        release_queue: release_holder,
        holder_thread:,
        contender_thread:
      )

      assert_not relationship_created
      assert_includes service_errors.join(' '), 'guardian must be an active constituent'
      assert_not GuardianRelationship.exists?(guardian_id: guardian.id, dependent_id: dependent.id)
      assert guardian.reload.merged?
      assert_equal survivor.id, guardian.merged_into_user_id
    ensure
      cleanup_duplicate_review_test_data!(guardian, survivor, dependent)
    end
  end
end
