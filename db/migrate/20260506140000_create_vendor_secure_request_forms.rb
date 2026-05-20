# frozen_string_literal: true

class CreateVendorSecureRequestForms < ActiveRecord::Migration[8.0]
  def up
    create_table :vendor_secure_request_forms do |t|
      t.references :vendor, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :kind, null: false, default: 0
      t.integer :status, null: false, default: 0
      t.string :recipient_email, null: false
      t.string :public_token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :sent_at, null: false
      t.datetime :submitted_at
      t.datetime :revoked_at
      t.string :request_batch_id, null: false
      t.references :requested_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :vendor_secure_request_forms,
              :public_token_digest,
              unique: true,
              name: 'idx_vendor_secure_forms_on_public_token_digest'
    add_index :vendor_secure_request_forms,
              %i[vendor_id kind],
              unique: true,
              where: 'status = 0 AND kind = 0',
              name: 'idx_vendor_secure_forms_one_active_w9_vendor'
    add_index :vendor_secure_request_forms,
              %i[vendor_id kind sent_at],
              name: 'idx_vendor_secure_forms_on_vendor_kind_sent_at'

    add_check_constraint :vendor_secure_request_forms,
                         'kind = 0',
                         name: 'vendor_secure_request_forms_kind_check'
    add_check_constraint :vendor_secure_request_forms,
                         'status = ANY (ARRAY[0, 1, 2])',
                         name: 'vendor_secure_request_forms_status_check'
  end

  def down
    drop_table :vendor_secure_request_forms
  end
end
