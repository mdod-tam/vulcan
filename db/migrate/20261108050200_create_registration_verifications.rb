# frozen_string_literal: true

class CreateRegistrationVerifications < ActiveRecord::Migration[8.1]
  def change
    create_table :registration_verifications do |t|
      t.text :email, null: false
      t.string :locale, null: false, default: 'en'
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.references :created_user, foreign_key: { to_table: :users }
      t.string :delivery_status, null: false, default: 'pending'
      t.timestamps
    end
    add_index :registration_verifications, :expires_at
  end
end
