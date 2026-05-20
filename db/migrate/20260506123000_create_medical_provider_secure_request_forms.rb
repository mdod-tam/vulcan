# frozen_string_literal: true

class CreateMedicalProviderSecureRequestForms < ActiveRecord::Migration[8.0]
  def up
    create_table :medical_provider_secure_request_forms do |t|
      t.references :application, null: false, foreign_key: { on_delete: :cascade }
      t.integer :kind, null: false, default: 0
      t.integer :status, null: false, default: 0
      t.string :provider_email, null: false
      t.string :provider_name
      t.string :public_token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :sent_at, null: false
      t.datetime :submitted_at
      t.datetime :revoked_at
      t.string :request_batch_id, null: false
      t.references :requested_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :medical_provider_secure_request_forms,
              :public_token_digest,
              unique: true,
              name: 'idx_med_provider_secure_forms_on_public_token_digest'
    add_index :medical_provider_secure_request_forms,
              %i[application_id kind provider_email],
              unique: true,
              where: 'status = 0 AND kind = 0',
              name: 'idx_med_provider_secure_forms_one_active_provider'
    add_index :medical_provider_secure_request_forms,
              %i[application_id kind provider_email sent_at],
              name: 'idx_med_provider_secure_forms_on_app_kind_email_sent'

    add_check_constraint :medical_provider_secure_request_forms,
                         'kind = 0',
                         name: 'medical_provider_secure_request_forms_kind_check'
    add_check_constraint :medical_provider_secure_request_forms,
                         'status = ANY (ARRAY[0, 1, 2])',
                         name: 'medical_provider_secure_request_forms_status_check'
  end

  def down
    drop_table :medical_provider_secure_request_forms
  end
end
