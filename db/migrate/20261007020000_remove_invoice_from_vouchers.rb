# frozen_string_literal: true

# Invoices link to voucher transactions, never to vouchers; nothing ever set this column.
class RemoveInvoiceFromVouchers < ActiveRecord::Migration[8.1]
  def change
    remove_reference :vouchers, :invoice, foreign_key: true, index: true
  end
end
