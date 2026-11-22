# frozen_string_literal: true

class AddIcanconnectWorkflows < ActiveRecord::Migration[8.1]
  def change
    %i[bid_groups purchase_orders equipment_items].each do |table|
      add_column table, :funding_source, :string, null: false, default: 'mat'
      add_check_constraint table, "funding_source IN ('mat', 'icanconnect')", name: "#{table}_funding_source"
    end
    change_table :equipment_items, bulk: true do |t|
      t.decimal :unit_cost, precision: 12, scale: 2
      t.date :delivered_on
      t.date :installed_on
    end
    change_table :purchase_orders, bulk: true do |t|
      t.decimal :shipping_cost, :other_cost, :invoice_total, precision: 12, scale: 2
      t.string :other_cost_category, :vendor_invoice_number, :vendor_name
      t.date :invoice_on
    end

    %i[evaluations training_sessions].each do |table|
      change_table table, bulk: true do |t|
        t.string :funding_source
        t.date :funding_service_on
        t.decimal :hourly_rate, precision: 12, scale: 2
        t.decimal :billable_hours, :mileage, precision: 8, scale: 2
        t.decimal :mileage_rate, precision: 6, scale: 3
        t.string :vendor_invoice_number
        t.integer :lock_version, null: false, default: 0
      end
      add_check_constraint table, "funding_source IS NULL OR funding_source IN ('mat', 'icanconnect')", name: "#{table}_funding_source"
    end

    create_table :mileage_rates do |t|
      t.date :effective_on, null: false
      t.decimal :dollars_per_mile, precision: 6, scale: 3, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index :effective_on, unique: true
      t.check_constraint 'dollars_per_mile >= 0', name: 'mileage_rates_nonnegative'
    end

    create_table :application_service_expenses do |t|
      t.references :application, null: false, foreign_key: true
      t.references :equipment_item, null: false, foreign_key: true
      t.string :category, null: false
      t.date :service_date, null: false
      t.decimal :amount, precision: 12, scale: 2
      t.string :vendor_invoice_number
      t.string :vendor_name
      t.string :funding_source, null: false, default: 'icanconnect'
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :application_service_expenses, "category IN ('installation', 'interpretation', 'travel') AND funding_source = 'icanconnect'",
                         name: 'icc_service_expense_category_and_fund'

    create_table :training_session_equipment_items do |t|
      t.references :training_session, null: false, foreign_key: true
      t.references :equipment_item, null: false, foreign_key: true
      t.timestamps
    end
    add_index :training_session_equipment_items, %i[training_session_id equipment_item_id], unique: true, name: 'unique_training_equipment_link'

    add_filing_markers
    add_cost_constraints
  end

  private

  def add_filing_markers
    %i[equipment_items purchase_orders evaluations training_sessions application_service_expenses].each do |table|
      change_table table, bulk: true do |t|
        t.string :icc_claim_period, :icc_external_filing_reference
        t.datetime :icc_claimed_at
        t.references :icc_claimed_by, foreign_key: { to_table: :users }
      end
      complete_marker = <<~SQL.squish
        (icc_claimed_at IS NULL AND icc_claimed_by_id IS NULL AND icc_claim_period IS NULL AND icc_external_filing_reference IS NULL)
        OR (icc_claimed_at IS NOT NULL AND icc_claimed_by_id IS NOT NULL AND icc_claim_period IS NOT NULL AND icc_external_filing_reference IS NOT NULL)
      SQL
      add_check_constraint table, complete_marker, name: "#{table}_icc_claim_complete"
    end
  end

  def add_cost_constraints
    service_costs = %i[hourly_rate billable_hours mileage mileage_rate]
    { equipment_items: %i[unit_cost], purchase_orders: %i[shipping_cost other_cost invoice_total], evaluations: service_costs,
      training_sessions: service_costs, application_service_expenses: %i[amount] }.each do |table, fields|
      fields.each { |field| add_check_constraint table, "#{field} IS NULL OR #{field} >= 0", name: "#{table}_#{field}_nonnegative" }
    end
  end
end
