# frozen_string_literal: true

class CreateVoucherVerificationThrottles < ActiveRecord::Migration[8.1]
  def change
    create_table :voucher_verification_throttles do |t|
      t.references :voucher, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :vendor, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.integer :failed_attempts, null: false, default: 0
      t.datetime :window_started_at
      t.datetime :locked_until
      t.timestamps
    end

    add_index :voucher_verification_throttles, %i[voucher_id vendor_id],
              unique: true, name: 'index_voucher_verification_throttles_on_voucher_and_vendor'
  end
end
