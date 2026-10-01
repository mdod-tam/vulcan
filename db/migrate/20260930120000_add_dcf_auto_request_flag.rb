# frozen_string_literal: true

class AddDcfAutoRequestFlag < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      INSERT INTO feature_flags (name, enabled, delivery_generation, created_at, updated_at)
      VALUES ('dcf_auto_request_certification', FALSE, 0, NOW(), NOW())
      ON CONFLICT (name) DO NOTHING
    SQL
  end

  def down
    execute "DELETE FROM feature_flags WHERE name = 'dcf_auto_request_certification'"
  end
end
