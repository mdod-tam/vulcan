# frozen_string_literal: true

class CreateVoucherTransactionShipments < ActiveRecord::Migration[8.1]
  def change
    # How a completed purchase reaches the constituent. Changed only through
    # VoucherTransactions::FulfillmentService, which compares fulfillment_version to detect stale forms.
    change_table :voucher_transactions, bulk: true do |t|
      t.integer :fulfillment_mode, null: false, default: 0
      t.integer :fulfillment_version, null: false, default: 0
    end

    create_table :voucher_transaction_shipments do |t|
      t.references :voucher_transaction, null: false, foreign_key: true, index: false
      t.string :tracking_number, null: false
      # Upper-cased without spaces or hyphens; only used to refuse the same package twice in one purchase.
      t.string :normalized_tracking_number, null: false
      t.date :dispatched_on
      t.text :contents
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }
      t.integer :lock_version, null: false, default: 0
      # The package's first-tracking notice. Set once; an unset value means the notice is still owed.
      t.references :tracking_notification, foreign_key: { to_table: :notifications },
                                           index: { unique: true, name: 'index_shipments_on_tracking_notification' }
      t.timestamps
    end

    add_index :voucher_transaction_shipments, %i[voucher_transaction_id normalized_tracking_number],
              unique: true, name: 'index_shipments_on_transaction_and_tracking'
  end
end
