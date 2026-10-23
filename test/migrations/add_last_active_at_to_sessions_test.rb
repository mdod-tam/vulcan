# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/migrate/20261022173000_add_last_active_at_to_sessions'

class AddLastActiveAtToSessionsTest < ActiveSupport::TestCase
  setup do
    @connection = ActiveRecord::Base.connection
    # PostgreSQL resolves this connection-local table before the real sessions table.
    @connection.create_table(:sessions, temporary: true) { |table| table.string :session_token }
    @migration = AddLastActiveAtToSessions.new
  end

  teardown do
    @connection.execute('DROP TABLE IF EXISTS pg_temp.sessions')
    Session.reset_column_information
  end

  test 'populated sessions are signed out before adding required activity without a default' do
    @connection.execute("INSERT INTO sessions (session_token) VALUES ('old-session-one'), ('old-session-two')")

    @migration.up

    assert_equal 0, @connection.select_value('SELECT COUNT(*) FROM sessions').to_i
    activity = @connection.columns(:sessions).find { |column| column.name == 'last_active_at' }
    assert_not activity.null
    assert_nil activity.default
    @connection.execute("INSERT INTO sessions (session_token, last_active_at) VALUES ('new-session', CURRENT_TIMESTAMP)")
    assert_equal 1, @connection.select_value('SELECT COUNT(*) FROM sessions').to_i
  end

  test 'empty sessions migrate and rolling down removes the column' do
    @migration.up
    @migration.down

    assert_not_includes @connection.columns(:sessions).map(&:name), 'last_active_at'
    assert_equal 0, @connection.select_value('SELECT COUNT(*) FROM sessions').to_i
  end
end
