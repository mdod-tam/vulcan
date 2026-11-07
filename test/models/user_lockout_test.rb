# frozen_string_literal: true

require 'test_helper'

# Failed-login counting, lockout, and sign-in bookkeeping (UserAuthentication). The races between these
# writes and sign-in are in test/controllers/sessions_controller_concurrency_test.rb.
class UserLockoutTest < ActiveSupport::TestCase
  MAX = UserAuthentication::MAX_LOGIN_ATTEMPTS

  setup do
    ensure_system_audit_actor!
    @user = create(:constituent)
  end

  test 'account_locked? reads without changing an expired lock' do
    expired_at = expired_lock_time
    @user.update_columns(failed_attempts: MAX, locked_at: expired_at)

    assert_not @user.reload.account_locked?

    @user.reload
    assert_equal MAX, @user.failed_attempts
    assert_in_delta expired_at, @user.locked_at, 1.second
  end

  test 'a failed attempt below the limit counts without locking' do
    @user.record_failed_login!

    @user.reload
    assert_equal 1, @user.failed_attempts
    assert_nil @user.locked_at
  end

  test 'the last allowed failed attempt locks the account with the count' do
    @user.update_columns(failed_attempts: MAX - 1)

    @user.reload.record_failed_login!

    @user.reload
    assert_equal MAX, @user.failed_attempts
    assert_predicate @user, :account_locked?
  end

  test 'the last allowed failed attempt locks the account even when the profile is invalid' do
    @user.update_columns(first_name: '')
    assert_not @user.reload.valid?, 'precondition: the profile must be invalid'

    MAX.times { @user.reload.record_failed_login! }

    @user.reload
    assert_equal MAX, @user.failed_attempts
    assert_predicate @user, :account_locked?
  end

  test 'a stale instance cannot lose a count' do
    first = User.find(@user.id)
    second = User.find(@user.id)

    first.record_failed_login!
    second.record_failed_login!

    assert_equal 2, @user.reload.failed_attempts
  end

  test 'a failed attempt after the lock expires starts a fresh count' do
    @user.update_columns(failed_attempts: MAX, locked_at: expired_lock_time)

    @user.reload.record_failed_login!

    @user.reload
    assert_equal 1, @user.failed_attempts
    assert_nil @user.locked_at
    assert_not_predicate @user, :account_locked?
  end

  test 'sign-in tracking records the sign-in and clears the counter' do
    @user.update_columns(failed_attempts: MAX - 1)

    assert @user.reload.track_sign_in!('203.0.113.9')

    @user.reload
    assert_equal 0, @user.failed_attempts
    assert_equal '203.0.113.9', @user.last_sign_in_ip
    assert_not_nil @user.last_sign_in_at
  end

  test 'sign-in tracking succeeds with an invalid profile' do
    @user.update_columns(first_name: '')
    assert_not @user.reload.valid?, 'precondition: the profile must be invalid'

    assert @user.track_sign_in!('203.0.113.9')

    assert_equal '203.0.113.9', @user.reload.last_sign_in_ip
  end

  test 'sign-in tracking after the lock expires succeeds and clears the lock' do
    @user.update_columns(failed_attempts: MAX, locked_at: expired_lock_time)

    assert @user.reload.track_sign_in!('203.0.113.9')

    @user.reload
    assert_equal 0, @user.failed_attempts
    assert_nil @user.locked_at
    assert_equal '203.0.113.9', @user.last_sign_in_ip
  end

  test 'sign-in tracking while locked refuses and writes nothing' do
    @user.update_columns(failed_attempts: MAX, locked_at: Time.current)

    assert_not @user.reload.track_sign_in!('203.0.113.9')

    @user.reload
    assert_equal MAX, @user.failed_attempts
    assert_predicate @user, :account_locked?
    assert_nil @user.last_sign_in_ip
    assert_nil @user.last_sign_in_at
  end

  private

  def expired_lock_time
    (UserAuthentication::LOCK_DURATION + 1.minute).ago
  end
end
