# frozen_string_literal: true

class AddLastActiveAtToSessions < ActiveRecord::Migration[8.1]
  def up
    # Session activity starts at this release; require a fresh sign-in for stored sessions.
    execute 'DELETE FROM sessions'
    add_column :sessions, :last_active_at, :datetime, null: false # rubocop:disable Rails/NotNullColumn -- Stored sessions were cleared above.
  end

  def down
    remove_column :sessions, :last_active_at
  end
end
