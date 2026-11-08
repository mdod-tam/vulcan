# frozen_string_literal: true

class CreateSmsVerificationAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :sms_verification_attempts do |t|
      t.string :service_sid, null: false
      t.string :destination_digest, null: false
      t.text :phone_number, null: false
      t.string :purpose, null: false
      t.string :owner_digest, null: false
      t.string :verification_sid
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :ownership_expires_at, null: false
      t.datetime :last_sent_at
      t.string :send_version
      t.datetime :sending_until
      t.string :check_version
      t.datetime :checking_until
      t.integer :checks_count, null: false, default: 0
      t.datetime :approved_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :sms_verification_attempts, %i[service_sid destination_digest], unique: true,
                                                                              where: 'finished_at IS NULL', name: 'index_sms_verification_on_active_destination'
    add_index :sms_verification_attempts, :ownership_expires_at
  end
end
