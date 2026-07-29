# frozen_string_literal: true

require 'test_helper'

# Focused concurrency evidence for the "new merge blockers" boundary (plan section 4, row 5):
# recovery-request creation and the merge service must serialize through
# User.lock_for_merge_integrity! on the target user, so a request submitted right as (or
# after) the account is retired cannot commit a fresh blocker after merge's authoritative
# blocker check already passed.
#
# Exercises the real, private controller method directly (via a minimal
# ActionDispatch::TestRequest/TestResponse pair, using set_request!/set_response! -- see
# passwords_controller_concurrency_test.rb for why) rather than through routing. Both sides
# of every race are real production code.
class AccountRecoveryControllerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'merge commits first: recovery-request submission for the newly-merged duplicate refuses with zero new pending requests' do
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
    contender_thread = on_own_connection do
      contender_pid_queue << backend_pid
      run_recovery_submission(duplicate)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
    assert_equal 0, duplicate.reload.recovery_requests.pending.count,
                 'zero side effects: the merged duplicate must gain no new pending recovery request'
  ensure
    cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
  end

  test 'recovery-request submission commits first: the merge then fails closed on the freshly-pending request' do
    admin, canonical, duplicate, review_case = build_fixtures

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        run_recovery_submission(duplicate)
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

    assert_equal 1, duplicate.reload.recovery_requests.pending.count, 'the committed submission must have created its pending request'
    assert merge_result.failure?, 'expected the merge to fail closed against the freshly-pending recovery request'
    assert_match(/pending recovery request/i, merge_result.message)
    assert_not duplicate.merged?, 'zero side effects: the duplicate must remain unmerged'
  ensure
    cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
  end

  test 'recovery notification creation and merge interleave without a requester-to-actor lock inversion' do
    admin, canonical, duplicate, review_case = build_fixtures
    notification_ready = Queue.new
    release_notification = Queue.new
    holder_pid_queue = Queue.new

    controller_class = Class.new(AccountRecoveryController) do
      private

      def notify_admins_of_recovery_request!(...)
        @notification_ready << true
        @release_notification.pop
        super
      end
    end

    recovery_thread = on_own_connection do
      holder_pid_queue << backend_pid
      run_recovery_submission(
        duplicate,
        controller_class: controller_class,
        notification_ready: notification_ready,
        release_notification: release_notification
      )
    end
    holder_pid = wait_for_signal(holder_pid_queue, thread: recovery_thread)
    wait_for_signal(notification_ready, thread: recovery_thread)

    contender_pid_queue = Queue.new
    merge_result = nil
    merge_thread = on_own_connection do
      contender_pid_queue << backend_pid
      merge_result = run_merge(admin:, canonical:, duplicate:, review_case:)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: merge_thread),
      holder_pid: holder_pid,
      release_queue: release_notification,
      holder_thread: recovery_thread,
      contender_thread: merge_thread
    )

    assert_equal 1, duplicate.reload.recovery_requests.pending.count
    assert_equal 1, Notification.where(
      action: 'security_key_recovery_requested',
      recipient_id: admin.id,
      actor_id: duplicate.id
    ).count
    assert merge_result.failure?, 'the merge must observe and fail closed on the interleaved pending request'
    assert_match(/pending recovery request/i, merge_result.message)
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
      duplicate = create(:constituent, email: nil, phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
                                       communication_preference: :letter)
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
      contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' },
      delivery_choice: 'canonical'
    ).call
  end

  def run_recovery_submission(user, controller_class: AccountRecoveryController, notification_ready: nil,
                              release_notification: nil)
    controller = controller_class.new
    controller.set_request!(ActionDispatch::TestRequest.create)
    controller.set_response!(ActionDispatch::TestResponse.new)
    controller.instance_variable_set(:@notification_ready, notification_ready)
    controller.instance_variable_set(:@release_notification, release_notification)
    controller.params = ActionController::Parameters.new(details: 'lost my security key')

    controller.send(:submit_recovery_request, User.find(user.id))
  end
end
