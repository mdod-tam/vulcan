# frozen_string_literal: true

class AddTaxCostToPurchaseOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :purchase_orders, :tax_cost, :decimal, precision: 12, scale: 2
    add_check_constraint :purchase_orders, 'tax_cost IS NULL OR tax_cost >= 0', name: 'purchase_orders_tax_cost_nonnegative'
  end
end
