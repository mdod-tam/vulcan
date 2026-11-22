# frozen_string_literal: true

class CreatePurchaseOrderShippingRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :purchase_order_shipping_requests do |t|
      t.references :purchase_order, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.string :recipient_email, null: false
      t.text :shipping_instructions
      t.string :public_token_digest, null: false, index: { unique: true }
      t.uuid :request_batch_id, null: false
      t.integer :status, null: false, default: 0
      t.string :delivery_status, null: false, default: 'pending'
      t.datetime :sent_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :submitted_at
      t.datetime :revoked_at
      t.datetime :expiration_recorded_at
      t.timestamps
    end
  end
end
