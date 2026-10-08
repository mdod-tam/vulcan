# frozen_string_literal: true

# One redemption form submission records at most one purchase. Historical rows keep NULL, which the
# unique index allows any number of.
class AddSubmissionIdToVoucherTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :voucher_transactions, :submission_id, :string
    add_index :voucher_transactions, :submission_id, unique: true
  end
end
