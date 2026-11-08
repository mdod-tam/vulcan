# frozen_string_literal: true

class CreateAuthRateLimitCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :auth_rate_limit_counters do |t|
      t.string :key, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :auth_rate_limit_counters, :key, unique: true
    add_index :auth_rate_limit_counters, :expires_at
    add_check_constraint :auth_rate_limit_counters, 'attempts >= 0', name: 'auth_rate_limit_counters_attempts_nonnegative'
  end
end
