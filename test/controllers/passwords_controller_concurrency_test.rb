# frozen_string_literal: true

require 'test_helper'

# Focused concurrency evidence for the password-reset consumption boundary (plan section 4):
# PasswordsController#update_password_from_token and the merge service must serialize
# through User.lock_for_merge_integrity! on the target user.
#
# Exercises the real, private controller method directly (via a minimal
# ActionDispatch::TestRequest/TestResponse pair and ActionController::Parameters, not a full
# HTTP dispatch) rather than through routing, matching the same technique used for the
# session-creation boundary. Both sides of every race are real production code.
class PasswordsControllerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'merge commits first: consuming the reset token for the newly-merged duplicate then fails closed' do
    admin, canonical, duplicate, review_case = build_fixtures
    original_digest = duplicate.password_digest

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
    reset_response = nil
    contender_thread = on_own_connection do
      contender_pid_queue << backend_pid
      reset_response = run_password_reset(duplicate)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
    assert_equal :redirect, reset_response[:action]
    assert_match(/invalid or expired/i, reset_response[:alert])
    assert_equal original_digest, duplicate.reload.password_digest,
                 "zero side effects: the merged duplicate's password must be untouched by the losing reset attempt"
  ensure
    cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
  end

  test 'password reset commits first: the merge then proceeds normally' do
    admin, canonical, duplicate, review_case = build_fixtures
    original_digest = duplicate.password_digest

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    reset_response = nil
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        reset_response = run_password_reset(duplicate)
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

    assert_equal :redirect, reset_response[:action]
    assert_equal 'Password successfully updated.', reset_response[:notice]
    assert_not_equal original_digest, duplicate.reload.password_digest, 'the committed reset must have taken effect'
    assert merge_result.success?, "expected the merge to proceed normally once the password reset committed: #{merge_result&.message}"
  ensure
    cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
  end

  # Not a merge scenario: proves the specific mechanism added alongside the merge-integrity
  # lock in update_password_from_token -- re-resolving the token itself under lock, not just
  # rechecking merge eligibility. A token issued before this test starts is used *after* a
  # concurrent password change (any concurrent change, not only a merge) commits, while the
  # reset request waited on the same user's lock. Without the fix, the stale token's payload
  # was only checked once, unlocked, before that change -- and would still have landed.
  test 'a concurrent password change commits first: the now-stale reset token then fails closed with zero writes' do
    user = create(:constituent, password: 'OriginalPass123!', password_confirmation: 'OriginalPass123!')
    stale_token = User.find(user.id).generate_token_for(:password_reset)

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        locked_user = User.lock_for_merge_integrity!(user).fetch(user.id)
        locked_user.update!(password: 'ChangedConcurrently123!', password_confirmation: 'ChangedConcurrently123!')
        holder_ready << true
        release_holder.pop
      end
    end
    holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
    wait_for_signal(holder_ready, thread: holder_thread)

    contender_pid_queue = Queue.new
    reset_response = nil
    contender_thread = on_own_connection do
      contender_pid_queue << backend_pid
      reset_response = run_password_reset_with_token(token: stale_token)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    assert_equal :redirect, reset_response[:action]
    assert_match(/invalid or expired/i, reset_response[:alert])
    # #reload (not a fresh User.find): this connection already queried this same user once
    # above (via generate_token_for), so a repeated User.find(user.id) here would be exactly
    # the query-cache trap ConcurrencyTestHelper's setup now defends against -- reload always
    # bypasses the cache regardless.
    user.reload
    assert user.authenticate('ChangedConcurrently123!'), 'the concurrent password change must survive untouched'
    assert_not user.authenticate('NewPassword123!'),
               "zero side effects: the stale token's own password value must never have been applied"
  ensure
    user&.destroy
  end

  private

  def build_fixtures
    admin = create(:admin)
    canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
    duplicate = nil
    begin
      Current.paper_context = true
      duplicate = create(:constituent, email: nil, phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
                                       communication_preference: :letter,
                                       password: 'OriginalPass123!', password_confirmation: 'OriginalPass123!')
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

  # Drives PasswordsController#update_password_from_token directly with a real generated
  # token, and reports back what the action *did* (redirect target + flash) rather than
  # relying on view rendering, since this bypasses the normal render pipeline.
  def run_password_reset(user)
    run_password_reset_with_token(token: User.find(user.id).generate_token_for(:password_reset))
  end

  def run_password_reset_with_token(token:)
    controller = PasswordsController.new
    # set_request!/set_response! (not the public request=/response= setters): Metal#response=
    # deliberately forces performed? to true as a side effect ("no further processing will
    # occur"), which is correct for attaching an already-completed response but would make
    # the very first real redirect_to/render call below raise DoubleRenderError immediately.
    controller.set_request!(ActionDispatch::TestRequest.create)
    controller.set_response!(ActionDispatch::TestResponse.new)
    controller.params = ActionController::Parameters.new(
      token: token,
      password: 'NewPassword123!',
      password_confirmation: 'NewPassword123!'
    )

    controller.send(:update_password_from_token)

    response_summary(controller)
  end

  def response_summary(controller)
    if controller.response.redirect?
      { action: :redirect, location: controller.response.location, notice: controller.send(:flash)[:notice],
        alert: controller.send(:flash)[:alert] }
    else
      { action: :render, alert: controller.send(:flash).now[:alert] }
    end
  end
end
