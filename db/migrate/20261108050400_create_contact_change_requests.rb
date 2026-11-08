# frozen_string_literal: true

class CreateContactChangeRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :contact_change_requests do |t|
      t.references :user, null: false, foreign_key: true
      t.references :session, foreign_key: { on_delete: :nullify }
      t.string :kind, null: false
      t.text :old_value
      t.text :proposed_value
      t.text :notification_email
      t.string :phone_type
      t.string :locale, null: false, default: 'en'
      t.bigint :security_version, null: false
      t.boolean :old_confirmation_required, null: false, default: false
      t.datetime :expires_at, null: false
      t.datetime :old_confirmed_at
      t.datetime :new_confirmed_at
      t.string :sms_verification_sid
      t.datetime :sms_expires_at
      t.datetime :completed_at
      t.datetime :canceled_at
      t.jsonb :delivery_states, null: false, default: {}
      t.jsonb :delivery_contexts, null: false, default: {}
      t.timestamps
    end
    add_index :contact_change_requests, :user_id, unique: true,
                                                  where: 'completed_at IS NULL AND canceled_at IS NULL', name: 'index_contact_changes_on_current_user'
    add_check_constraint :contact_change_requests, "kind IN ('email', 'phone')", name: 'contact_change_kind'
    add_index :contact_change_requests, :expires_at
  end
end
