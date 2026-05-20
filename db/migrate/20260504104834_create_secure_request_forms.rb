# frozen_string_literal: true

class CreateSecureRequestForms < ActiveRecord::Migration[8.0]
  PRINT_QUEUE_LETTER_TYPE_CONSTRAINT = :check_print_queue_items_on_letter_type

  def up
    create_table :secure_request_forms do |t|
      t.references :application, null: false, foreign_key: true
      t.integer :kind, null: false, default: 0
      t.integer :status, null: false, default: 0
      t.string :request_batch_id, null: false
      t.references :recipient, null: false, foreign_key: { to_table: :users }
      t.string :recipient_email
      t.string :recipient_phone
      t.integer :recipient_channel, null: false
      t.integer :recipient_role, null: false
      t.string :recipient_relationship_type
      t.string :public_token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :sent_at, null: false
      t.references :requested_by, foreign_key: { to_table: :users }
      t.datetime :submitted_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :secure_request_forms,
              %i[application_id kind request_batch_id],
              name: 'idx_secure_request_forms_on_app_kind_batch'
    add_index :secure_request_forms,
              :public_token_digest,
              unique: true,
              name: 'idx_secure_request_forms_on_public_token_digest'
    add_index :secure_request_forms,
              %i[application_id kind recipient_id],
              unique: true,
              where: 'status = 0 AND kind = 0',
              name: 'idx_secure_request_forms_one_active_provider_recipient'
    add_index :secure_request_forms,
              %i[application_id kind recipient_id sent_at],
              name: 'idx_secure_request_forms_on_app_kind_recipient_sent_at'

    add_check_constraint :secure_request_forms, 'kind = 0', name: 'secure_request_forms_kind_check'
    add_check_constraint :secure_request_forms,
                         'status = ANY (ARRAY[0, 1, 2])',
                         name: 'secure_request_forms_status_check'
    add_check_constraint :secure_request_forms,
                         'recipient_channel = ANY (ARRAY[0, 1, 2])',
                         name: 'secure_request_forms_recipient_channel_check'
    add_check_constraint :secure_request_forms,
                         'recipient_role = ANY (ARRAY[0, 1])',
                         name: 'secure_request_forms_recipient_role_check'
    widen_print_queue_letter_type_check!(upper_bound: 12)
  end

  def down
    widen_print_queue_letter_type_check!(upper_bound: 11)
    drop_table :secure_request_forms
  end

  private

  def widen_print_queue_letter_type_check!(upper_bound:)
    remove_check_constraint :print_queue_items,
                            name: PRINT_QUEUE_LETTER_TYPE_CONSTRAINT,
                            if_exists: true
    add_check_constraint :print_queue_items,
                         "letter_type >= 0 AND letter_type <= #{upper_bound}",
                         name: PRINT_QUEUE_LETTER_TYPE_CONSTRAINT
  end
end
