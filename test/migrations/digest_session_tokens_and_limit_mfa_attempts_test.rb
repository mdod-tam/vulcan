# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/migrate/20261030183000_digest_session_tokens_and_limit_mfa_attempts'

class DigestSessionTokensAndLimitMfaAttemptsTest < ActiveSupport::TestCase
  setup do
    @connection = ActiveRecord::Base.connection
    @connection.create_table(:sessions, temporary: true) { |table| table.string :session_token }
    @connection.create_table(:users, temporary: true)
    @migration = DigestSessionTokensAndLimitMfaAttempts.new
  end

  teardown do
    @connection.execute('DROP TABLE IF EXISTS pg_temp.sessions')
    @connection.execute('DROP TABLE IF EXISTS pg_temp.users')
    Session.reset_column_information
    User.reset_column_information
  end

  test 'cutover revokes old sessions and requires unique digests without storing raw tokens' do
    @connection.execute("INSERT INTO sessions (session_token) VALUES ('old-session')")
    @connection.execute('INSERT INTO users DEFAULT VALUES')

    @migration.up

    assert_equal 0, @connection.select_value('SELECT COUNT(*) FROM sessions').to_i
    columns = @connection.columns(:sessions)
    assert_not_includes columns.map(&:name), 'session_token'
    assert_not columns.find { |column| column.name == 'session_token_digest' }.null
    assert(@connection.indexes(:sessions).any? { |index| index.unique && index.columns == ['session_token_digest'] })
    assert_equal 0, @connection.select_value('SELECT totp_failed_attempts FROM users').to_i
    assert_nil @connection.select_value('SELECT totp_attempt_window_started_at FROM users')
  end

  test 'rollback revokes digest sessions and restores the previous nullable raw-token schema' do
    @migration.up
    @connection.execute("INSERT INTO sessions (session_token_digest) VALUES ('digest')")

    @migration.down

    assert_equal 0, @connection.select_value('SELECT COUNT(*) FROM sessions').to_i
    columns = @connection.columns(:sessions)
    assert columns.find { |column| column.name == 'session_token' }.null
    assert_not_includes columns.map(&:name), 'session_token_digest'
    assert_not_includes @connection.columns(:users).map(&:name), 'totp_failed_attempts'
  end
end
