# frozen_string_literal: true

class DigestSessionTokensAndLimitMfaAttempts < ActiveRecord::Migration[8.1]
  def up
    # Revoke existing sign-ins at the direct cutover; raw tokens are not retained or backfilled.
    execute 'DELETE FROM sessions'
    remove_column :sessions, :session_token
    add_column :sessions, :session_token_digest, :string
    change_column_null :sessions, :session_token_digest, false
    add_index :sessions, :session_token_digest, unique: true

    add_column :users, :totp_failed_attempts, :integer, null: false, default: 0
    add_column :users, :totp_attempt_window_started_at, :datetime
    add_check_constraint :users, 'totp_failed_attempts >= 0', name: 'users_totp_failed_attempts_nonnegative'
  end

  def down
    execute 'DELETE FROM sessions'
    remove_column :sessions, :session_token_digest
    add_column :sessions, :session_token, :string
    add_index :sessions, :session_token, unique: true

    remove_check_constraint :users, name: 'users_totp_failed_attempts_nonnegative'
    remove_column :users, :totp_attempt_window_started_at
    remove_column :users, :totp_failed_attempts
  end
end
