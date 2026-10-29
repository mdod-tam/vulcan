# frozen_string_literal: true

# Certification upload requests now live in secure_request_forms (kind 4). Per the pre-1.0 baseline there is no
# backfill: existing provider rows are dropped with their table.
#
# Two tables point at forms polymorphically. A reference to a class that no longer exists cannot load, so rows
# that name the dropped model are cleared first: a delivery attempt keeps its history without its origin, and a
# staged upload scan owned by a dropped form has no owner left and goes with it.
class DropMedicalProviderSecureRequestForms < ActiveRecord::Migration[8.0]
  DROPPED_MODEL = 'MedicalProviderSecureRequestForm'

  def up
    execute "UPDATE email_delivery_attempts SET origin_type = NULL, origin_id = NULL WHERE origin_type = '#{DROPPED_MODEL}'"
    execute "DELETE FROM document_scans WHERE secure_form_type = '#{DROPPED_MODEL}'"
    drop_table :medical_provider_secure_request_forms
  end

  # Recreates the empty table. The rows cleared above are not restored.
  def down
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
      t.datetime :expiration_recorded_at # added after the table, so it is last
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
    add_index :medical_provider_secure_request_forms, %i[application_id kind provider_email sent_at],
              name: 'idx_med_provider_secure_forms_on_app_kind_email_sent'
    add_index :medical_provider_secure_request_forms, :expires_at,
              where: '(status = 0) AND (submitted_at IS NULL) AND (revoked_at IS NULL) AND (expiration_recorded_at IS NULL)',
              name: 'index_med_provider_secure_forms_on_open_expiration'
    add_check_constraint :medical_provider_secure_request_forms, 'kind = 0', name: 'medical_provider_secure_request_forms_kind_check'
    add_check_constraint :medical_provider_secure_request_forms, 'status = ANY (ARRAY[0, 1, 2])',
                         name: 'medical_provider_secure_request_forms_status_check'
  end
end
