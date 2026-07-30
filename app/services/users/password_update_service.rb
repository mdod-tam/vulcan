# frozen_string_literal: true

module Users
  # Service object to handle updating a user's password.
  class PasswordUpdateService < BaseService
    def initialize(user, password_challenge, new_password, new_password_confirmation)
      super()
      @user = user
      @password_challenge = password_challenge
      @new_password = new_password
      @new_password_confirmation = new_password_confirmation
      @errors = []
    end

    def call
      return fail_with_error('User not found.') unless @user

      result = nil
      ActiveRecord::Base.transaction { result = update_password_under_lock }
      result
    rescue ActiveRecord::RecordNotFound
      # The row disappeared between the caller loading this instance and the lock being
      # granted; fail closed rather than authenticating against a stale in-memory record.
      fail_with_error('User not found.')
    end

    private

    # Locks the user row before re-running the password challenge and writing, so a concurrent
    # merge and a concurrent password change can never interleave: either the merge commits
    # first and this reload sees the retired record and refuses, or the password change commits
    # first and the merge -- which takes the same lock -- waits. The challenge is re-run against
    # the freshly locked row, not the caller's pre-lock instance: a merge may retire the record,
    # or another password change may invalidate the digest, while this request waits, and a
    # stale authentication must not authorize the write that lands afterwards. Mirrors
    # PasswordsController#update_password_from_token and
    # ApplicationController#_create_and_set_session_cookie.
    def update_password_under_lock
      @user = User.lock_for_merge_integrity!(@user).fetch(@user.id)

      return fail_with_error('This account is no longer eligible to change its password.') unless @user.public_login_active?

      return fail_with_error('Current password is incorrect.') unless @user.authenticate(@password_challenge)

      return fail_with_error('New password and confirmation do not match.') unless @new_password == @new_password_confirmation

      if @user.update(password: @new_password, force_password_change: false)
        success_result(message: 'Password successfully updated.')
      else
        fail_with_error('Unable to update password. Please check requirements.', @user.errors.full_messages)
      end
    end

    def fail_with_error(message, details = [])
      @errors << message
      @errors.concat(details) if details.present?
      BaseService::Result.new(success: false, message: @errors.join(', '))
    end

    def success_result(data = {})
      BaseService::Result.new(success: true, data: data, message: 'Password successfully updated.')
    end
  end
end
