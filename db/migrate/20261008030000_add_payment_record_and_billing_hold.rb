# frozen_string_literal: true

# Who recorded an invoice payment and how it was paid, alongside the existing payment date and
# references; and a staff hold that keeps a purchase off every invoice until it is released.
class AddPaymentRecordAndBillingHold < ActiveRecord::Migration[8.1]
  def change
    change_table :invoices, bulk: true do |t|
      t.references :paid_by, foreign_key: { to_table: :users }
      t.integer :payment_method
    end

    change_table :voucher_transactions, bulk: true do |t|
      t.datetime :billing_hold_at
      t.references :billing_hold_by, foreign_key: { to_table: :users }
      t.text :billing_hold_reason
    end
  end
end
