# frozen_string_literal: true

# Adds the master email control. Turning a control off bumps delivery_generation, so mail
# captured under the earlier generation stays canceled after the control is turned back on.
# Existing rows keep their ids and generations; reruns never re-enable a control.
class AddEmailDeliveryControls < ActiveRecord::Migration[8.1]
  def up
    add_column :feature_flags, :delivery_generation, :bigint, default: 0, null: false

    execute <<~SQL.squish
      INSERT INTO feature_flags (name, enabled, delivery_generation, created_at, updated_at)
      VALUES ('email.global', TRUE, 0, NOW(), NOW())
      ON CONFLICT (name) DO NOTHING
    SQL
  end

  def down
    execute "DELETE FROM feature_flags WHERE name = 'email.global'"
    remove_column :feature_flags, :delivery_generation
  end
end
