# frozen_string_literal: true

class RemoveRetiredInvoiceDraftState < ActiveRecord::Migration[8.0]
  def change
    change_column_default :invoices, :status, from: 0, to: 1
  end
end
