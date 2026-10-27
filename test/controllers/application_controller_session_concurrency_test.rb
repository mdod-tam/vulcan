# frozen_string_literal: true

require 'test_helper'

# Concurrency tests for the session-creation boundary:
# ApplicationController#_create_and_set_session_cookie, the single chokepoint for both
# password sign-in and 2FA completion, and the merge service must serialize through
# User.lock_for_merge_integrity! on the target user.
#
# The tests call the real, private controller method directly with a minimal
# ActionDispatch::TestRequest/TestResponse pair instead of dispatching through routing, because
# session creation lives in a controller method rather than a service object. The method returns
# the same Session record (or nil) the sign-in and 2FA flows get. Both sides of every race are
# production code.
class ApplicationControllerSessionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'merge commits first: session creation for the newly-merged duplicate then fails closed with zero sessions' do
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
    session_record = :not_set
    contender_thread = on_own_connection do
      contender_pid_queue << backend_pid
      session_record = run_create_session(duplicate)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
    assert_nil session_record, 'expected session creation to fail closed once the target user was merged'
    assert_equal 0, duplicate.reload.sessions.count, 'zero side effects from the losing session-creation attempt'
  ensure
    cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
  end

  test 'session creation commits first: the merge then proceeds normally and expires the session it inherits' do
    admin, canonical, duplicate, review_case = build_fixtures

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    session_record = nil
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        session_record = run_create_session(duplicate)
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

    assert session_record.present?, 'expected session creation (holder) to succeed'
    assert merge_result.success?, "expected the merge to proceed normally once session creation committed: #{merge_result&.message}"
    assert_equal 0, duplicate.reload.sessions.count,
                 "the session committed before the merge must be picked up and destroyed by the merge's own expire_duplicate_sessions! step"
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

  def run_create_session(user)
    controller = ApplicationController.new
    # set_request!/set_response! rather than the public request=/response= setters, because
    # Metal#response= forces performed? to true. That would be harmless here, since
    # _create_and_set_session_cookie never renders or redirects. The other controller concurrency
    # tests do render or redirect, and this one uses the same setters for consistency.
    controller.set_request!(ActionDispatch::TestRequest.create)
    controller.set_response!(ActionDispatch::TestResponse.new)
    controller.send(:_create_and_set_session_cookie, User.find(user.id))
  end
end
