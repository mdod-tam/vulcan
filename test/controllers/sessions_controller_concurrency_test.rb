# frozen_string_literal: true

require 'test_helper'

# Focused concurrency evidence for the sign-in boundary (plan section 4, row 4;
# concurrency-evidence item 6: "password-only sign-in versus a contact-changing merge"):
# SessionsController#create (via the shared ApplicationController#_create_and_set_session_cookie
# chokepoint) and the merge service must serialize through User.lock_for_merge_integrity! on
# the target user.
#
# Exercises the real, private controller method directly (via a minimal
# ActionDispatch::TestRequest/TestResponse pair, using set_request!/set_response! -- see
# passwords_controller_concurrency_test.rb for why) rather than through routing. Both sides
# of every race are real production code.
class SessionsControllerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'merge commits first: phone-based sign-in for the newly-merged duplicate fails closed with zero sessions' do
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
    sign_in_response = nil
    contender_thread = on_own_connection do
      contender_pid_queue << backend_pid
      sign_in_response = run_sign_in(duplicate)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
    assert_equal :redirect, sign_in_response[:action]
    assert_equal 0, duplicate.reload.sessions.count, 'zero side effects: the merged duplicate must gain no session'
  ensure
    cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
  end

  test 'sign-in commits first: the merge then proceeds normally and expires the session it inherits' do
    admin, canonical, duplicate, review_case = build_fixtures

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    sign_in_response = nil
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        sign_in_response = run_sign_in(duplicate)
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

    assert_equal :redirect, sign_in_response[:action]
    assert_equal 'Signed in successfully', sign_in_response[:notice]
    assert merge_result.success?, "expected the merge to proceed normally once sign-in committed: #{merge_result&.message}"
    assert_equal 0, duplicate.reload.sessions.count,
                 "the session committed before the merge must be picked up and destroyed by the merge's own expire_duplicate_sessions! step"
  ensure
    cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
  end

  test 'password-only sign-in commits first: the session is valid and the later password change succeeds' do
    user = create(
      :constituent,
      email: "signin-wins-#{SecureRandom.hex(4)}@example.com",
      password: 'Password123!',
      password_confirmation: 'Password123!'
    )

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    sign_in_response = nil
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        sign_in_response = run_sign_in(user)
        holder_ready << true
        release_holder.pop
      end
    end
    holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
    wait_for_signal(holder_ready, thread: holder_thread)

    contender_pid_queue = Queue.new
    password_result = nil
    contender_thread = on_own_connection do
      contender_pid_queue << backend_pid
      password_result = run_password_change(user)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    assert_equal 'Signed in successfully', sign_in_response[:notice]
    assert sign_in_response[:session_cookie].present?, 'the winning sign-in must set its signed session cookie'
    assert password_result.success?, "expected the later password change to succeed: #{password_result.message}"
    assert_equal 1, user.reload.sessions.count
    assert user.authenticate('ChangedPassword123!')
    assert user.last_sign_in_at.present?, 'the winning sign-in must retain its normal sign-in audit fields'
  ensure
    cleanup_duplicate_review_test_data!(user)
  end

  test 'password change commits first: the old submitted password creates no session cookie or sign-in audit effects' do
    user = create(
      :constituent,
      email: "password-wins-#{SecureRandom.hex(4)}@example.com",
      password: 'Password123!',
      password_confirmation: 'Password123!'
    )
    original_sign_in_at = user.last_sign_in_at
    original_sign_in_ip = user.last_sign_in_ip
    original_event_count = Event.where(user_id: user.id).count

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    password_result = nil
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        password_result = run_password_change(user)
        holder_ready << true
        release_holder.pop
      end
    end
    holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
    wait_for_signal(holder_ready, thread: holder_thread)

    contender_pid_queue = Queue.new
    sign_in_response = nil
    contender_thread = on_own_connection do
      contender_pid_queue << backend_pid
      sign_in_response = run_sign_in(user)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    assert password_result.success?, "expected the password change (holder) to succeed: #{password_result.message}"
    assert_nil sign_in_response[:notice]
    assert sign_in_response[:alert].present?
    assert_nil sign_in_response[:session_cookie], 'the stale password must not set a signed session cookie'
    user.reload
    assert_equal 0, user.sessions.count
    assert_equal original_sign_in_at, user.last_sign_in_at
    assert_equal original_sign_in_ip, user.last_sign_in_ip
    assert_equal original_event_count, Event.where(user_id: user.id).count
    assert user.authenticate('ChangedPassword123!')
  ensure
    cleanup_duplicate_review_test_data!(user)
  end

  private

  def build_fixtures
    admin = create(:admin)
    canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
    # find_by_login_identifier requires real_email? even for a phone-based lookup (see
    # user.rb's find_by_login_identifier), so a meaningful "phone-based sign-in" fixture needs
    # both a real phone and a real email -- unlike the phone-only duplicate fixture used
    # elsewhere in this suite, which can never reach a password sign-in attempt at all.
    duplicate = create(:constituent, email: "dup-#{SecureRandom.hex(3)}@example.com",
                                     phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
                                     communication_preference: :letter,
                                     password: 'Password123!', password_confirmation: 'Password123!')

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

  def run_sign_in(user, password: 'Password123!')
    fresh_user = User.find(user.id)

    controller = SessionsController.new
    controller.set_request!(ActionDispatch::TestRequest.create)
    controller.set_response!(ActionDispatch::TestResponse.new)
    controller.instance_variable_set(:@_action_name, 'create')
    controller.params = ActionController::Parameters.new(
      contact: fresh_user.phone.presence || fresh_user.email,
      password: password
    )

    controller.send(:create)

    response_summary(controller)
  end

  def response_summary(controller)
    if controller.response.redirect?
      {
        action: :redirect,
        notice: controller.send(:flash)[:notice],
        alert: controller.send(:flash)[:alert],
        session_cookie: controller.send(:cookies).signed[:session_token]
      }
    else
      { action: :render }
    end
  end

  def run_password_change(user)
    Users::PasswordUpdateService.new(
      User.find(user.id),
      'Password123!',
      'ChangedPassword123!',
      'ChangedPassword123!'
    ).call
  end
end
