# frozen_string_literal: true

class CreateDocumentScans < ActiveRecord::Migration[8.1]
  def change
    create_table :document_scans do |t|
      t.references :blob, null: false, index: { unique: true }, foreign_key: { to_table: :active_storage_blobs, on_delete: :cascade }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :secure_form, polymorphic: true
      t.string :purpose, null: false
      t.string :slot, null: false
      t.string :form_context, null: false, default: ''
      t.string :status, null: false, default: 'pending'
      t.boolean :synthetic_fixture, null: false, default: false
      t.string :sha256, null: false
      t.string :provider_scan_id
      t.integer :attempts, null: false, default: 0
      t.integer :poll_count, null: false, default: 0
      t.string :last_error_code
      t.string :lease_token
      t.datetime :lease_expires_at
      t.datetime :next_attempt_at
      t.datetime :submitted_at
      t.datetime :completed_at
      t.datetime :continued_at
      t.datetime :dismissed_at
      t.string :continuation
      t.integer :continuation_attempts, null: false, default: 0
      t.datetime :continuation_next_attempt_at
      t.string :continuation_error_code
      t.string :dedup_key
      t.text :context
      t.timestamps
    end
    add_index :document_scans, :dedup_key, unique: true
    add_index :document_scans, :created_at
    add_index :document_scans, %i[continuation continued_at continuation_next_attempt_at], name: :index_document_scans_on_continuation_recovery
    add_index :document_scans, %i[status next_attempt_at]
    add_index :document_scans, %i[user_id purpose slot form_context], name: :index_document_scans_on_recovery
    add_check_constraint :document_scans, "status IN ('pending', 'clean', 'blocked', 'failed')", name: :document_scans_status
    add_check_constraint :document_scans,
                         "(user_id IS NOT NULL)::integer + (secure_form_id IS NOT NULL)::integer + COALESCE((continuation = 'docuseal')::integer, 0) <= 1",
                         name: :document_scans_owner
  end
end
