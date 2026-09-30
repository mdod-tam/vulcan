# frozen_string_literal: true

class CreateEmailDeliveryAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :email_delivery_attempts do |t|
      t.string :correlation_id, null: false
      t.string :recipient_key, null: false
      t.text :destination, null: false
      t.string :provider, null: false, default: 'postmark'
      t.string :server_id, null: false
      t.string :provider_message_id
      t.string :rfc_message_id
      t.string :mail_action, null: false
      t.string :state, null: false, default: 'unknown'
      t.references :notification, foreign_key: { on_delete: :nullify }
      t.references :application, foreign_key: { on_delete: :nullify }
      t.references :origin, polymorphic: true
      t.references :recipient, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :delivery_owner, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :bounce_event, foreign_key: { to_table: :events, on_delete: :nullify }
      t.datetime :attempted_at, null: false
      t.datetime :accepted_at
      t.datetime :delivered_at
      t.datetime :bounced_at
      t.datetime :complained_at
      t.datetime :delayed_at
      t.datetime :opened_at
      t.string :bounce_category
      t.datetime :feedback_at
      t.datetime :last_checked_at
      t.datetime :check_failed_at
      t.integer :check_count, null: false, default: 0
      t.timestamps
    end
    add_index :email_delivery_attempts, %i[correlation_id recipient_key], unique: true, name: 'email_attempt_correlation_recipient'
    add_index :email_delivery_attempts, %i[server_id provider_message_id recipient_key], unique: true, name: 'email_attempt_provider_recipient'
    add_check_constraint :email_delivery_attempts, "state IN ('unknown', 'accepted', 'failed')", name: 'email_attempt_state'
    add_check_constraint :email_delivery_attempts, 'check_count >= 0', name: 'email_attempt_check_count'

    create_table :email_delivery_receipts do |t|
      t.references :email_delivery_attempt, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_key, null: false
      t.string :kind, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :email_delivery_receipts, %i[email_delivery_attempt_id event_key], unique: true, name: 'email_receipt_event'
    add_check_constraint :email_delivery_receipts, "kind IN ('delivered', 'bounced', 'complained', 'opened', 'delayed')", name: 'email_receipt_kind'
  end
end
