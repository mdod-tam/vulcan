# frozen_string_literal: true

require 'test_helper'

module DuplicateReconciliation
  class ReviewPairServiceConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'concurrent reversed review entry creates one pair case and both callers reuse it' do
      admin = create(:admin)
      first, second = matching_pair
      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      holder_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          holder_result = review(admin, first.id, second.id)
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
        contender_result = review(admin, second.id, first.id)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid,
        release_queue: release_holder,
        holder_thread: holder_thread,
        contender_thread: contender_thread
      )

      assert holder_result.success?, holder_result.message
      assert contender_result.success?, contender_result.message
      assert contender_result.data.fetch(:idempotent)
      assert_equal holder_result.data.fetch(:duplicate_review_case).id,
                   contender_result.data.fetch(:duplicate_review_case).id
      cases = DuplicateReviewCase.where(source: :post_import_reconciliation, subject_user_id: [first.id, second.id])
      assert_equal 1, cases.count
      assert_equal 1, cases.first.duplicate_review_case_candidates.count
      assert_equal 1, Event.where(action: 'duplicate_review_case_opened', auditable_id: [first.id, second.id]).count
    ensure
      cleanup_duplicate_review_test_data!(admin, first, second)
    end

    private

    def matching_pair
      attributes = {
        first_name: 'Concurrent',
        last_name: "Pair#{SecureRandom.hex(4)}",
        date_of_birth: Date.new(1980, 6, 12),
        needs_duplicate_review: false
      }
      [
        create(:constituent, **attributes, email: "concurrent-a-#{SecureRandom.hex(5)}@example.com"),
        create(:constituent, **attributes, email: "concurrent-b-#{SecureRandom.hex(5)}@example.com")
      ]
    end

    def review(admin, first_id, second_id)
      ReviewPairService.new(
        actor: User.find(admin.id),
        first_user_id: first_id,
        second_user_id: second_id
      ).call
    end
  end
end
