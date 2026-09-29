# frozen_string_literal: true

class AddOutboundCommunicationControls < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    raise 'Missing email.global control; repair configuration before migration' unless
      select_value("SELECT id FROM feature_flags WHERE name = 'email.global'")

    execute <<~SQL.squish
      INSERT INTO feature_flags (name, enabled, delivery_generation, created_at, updated_at)
      SELECT 'communications.global', enabled, 0, NOW(), NOW() FROM feature_flags WHERE name = 'email.global'
      ON CONFLICT (name) DO NOTHING
    SQL
    execute <<~SQL.squish
      INSERT INTO feature_flags (name, enabled, delivery_generation, created_at, updated_at)
      VALUES ('communications.letters', TRUE, 0, NOW(), NOW()), ('communications.sms', TRUE, 0, NOW(), NOW())
      ON CONFLICT (name) DO NOTHING
    SQL

    add_column :print_queue_items, :delivery_key, :string unless column_exists?(:print_queue_items, :delivery_key)
    add_column :print_queue_items, :delivery_context, :jsonb unless column_exists?(:print_queue_items, :delivery_context)
    add_column :print_queue_items, :delivery_identity, :jsonb unless column_exists?(:print_queue_items, :delivery_identity)
    add_column :print_queue_items, :released_at, :datetime unless column_exists?(:print_queue_items, :released_at)
    add_column :print_queue_items, :canceled_at, :datetime unless column_exists?(:print_queue_items, :canceled_at)
    add_column :print_queue_items, :cancellation_reason, :string unless column_exists?(:print_queue_items, :cancellation_reason)
    add_reference :print_queue_items, :secure_request_form, foreign_key: true unless
      column_exists?(:print_queue_items, :secure_request_form_id)
    add_index :print_queue_items, :delivery_key, unique: true, where: 'delivery_key IS NOT NULL',
                                                 algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :print_queue_items, :delivery_key, algorithm: :concurrently, if_exists: true
    remove_reference :print_queue_items, :secure_request_form, foreign_key: true
    %i[delivery_key delivery_context delivery_identity released_at canceled_at cancellation_reason].each do |column|
      remove_column :print_queue_items, column
    end
    execute "DELETE FROM feature_flags WHERE name IN ('communications.global', 'communications.letters', 'communications.sms')"
  end
end
