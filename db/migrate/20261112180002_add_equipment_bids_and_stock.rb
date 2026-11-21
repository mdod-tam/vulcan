# frozen_string_literal: true

class AddEquipmentBidsAndStock < ActiveRecord::Migration[8.1]
  def change
    create_table :bid_groups do |t|
      t.string :number, null: false
      t.string :normalized_number, null: false
      t.string :purpose, null: false, default: 'direct_to_constituents'
      t.references :purchase_order, foreign_key: true
      t.datetime :cancelled_at
      t.datetime :membership_changed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :bid_groups, :normalized_number, unique: true
    create_table :bid_group_lines do |t|
      t.references :bid_group, null: false, foreign_key: true
      t.references :equipment_need, foreign_key: true
      t.references :equipment_item, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.integer :quantity, null: false
      t.string :supplier_setup_group
      t.datetime :released_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :bid_group_lines, 'quantity > 0', name: 'bid_line_positive_quantity'
    add_check_constraint :bid_group_lines, 'NOT (equipment_need_id IS NOT NULL AND equipment_item_id IS NOT NULL)', name: 'bid_line_one_source'
    remove_index :purchase_orders, %i[vendor_id normalized_number], name: 'index_purchase_orders_on_vendor_id_and_normalized_number', unique: true
    remove_reference :purchase_orders, :vendor, foreign_key: { to_table: :users }
    add_index :purchase_orders, :normalized_number, unique: true, name: 'index_purchase_orders_on_unique_number'
    change_column_null :purchase_orders, :sent_at, true
    add_column :purchase_orders, :purpose, :string, null: false, default: 'direct_to_constituents'
    %i[shipping_care_of shipping_address_1 shipping_address_2 shipping_city shipping_state shipping_zip_code].each do |field|
      add_column :purchase_orders, field, :text
      add_column :equipment_items, field, :text
    end
    add_column :equipment_needs, :disability_setup_group, :string
    add_column :equipment_needs, :unfulfilled_since, :datetime
    add_column :equipment_items, :disability_setup_group, :string
    add_column :equipment_items, :fulfillment_source, :string, null: false, default: 'direct_vendor'
    add_column :equipment_items, :stock_received_on, :date
    add_column :equipment_items, :stock_allocated_at, :datetime
    add_column :equipment_items, :intake_provenance, :text
    add_column :equipment_items, :po_assigned_at, :datetime
    add_column :equipment_items, :setup_confirmed_at, :datetime
    add_reference :equipment_items, :acquisition_bid_group_line, foreign_key: { to_table: :bid_group_lines }
    add_reference :equipment_items, :allocation_equipment_need, foreign_key: { to_table: :equipment_needs }
    add_reference :equipment_items, :replaced_by_equipment_item, foreign_key: { to_table: :equipment_items }, index: { unique: true }
    change_column_null :equipment_items, :application_id, true
    add_check_constraint :equipment_items, "fulfillment_source IN ('direct_vendor','program_stock_po','existing_stock')", name: 'equipment_source_allowed'
    add_check_constraint :equipment_items, "fulfillment_source != 'direct_vendor' OR application_id IS NOT NULL", name: 'direct_equipment_beneficiary'
    add_check_constraint :equipment_items, "fulfillment_source != 'program_stock_po' OR (purchase_order_id IS NOT NULL AND acquisition_bid_group_line_id IS NOT NULL)",
                         name: 'stock_acquisition_required'
    add_check_constraint :equipment_items, "fulfillment_source != 'existing_stock' OR (stock_received_on IS NOT NULL AND intake_provenance IS NOT NULL)",
                         name: 'existing_stock_provenance_required'
    add_reference :applications, :equipment_source_evaluation, foreign_key: { to_table: :evaluations }
    add_column :applications, :needs_evaluator_since, :datetime
    add_column :applications, :report_wait_started_at, :datetime
    remove_check_constraint :equipment_items, 'shipped_at IS NULL OR purchase_order_id IS NOT NULL', name: 'shipped_equipment_has_po'
    remove_check_constraint :equipment_items, 'withdrawn_at IS NULL OR (purchase_order_id IS NULL AND shipped_at IS NULL)', name: 'withdrawn_equipment_detached'
    add_check_constraint :equipment_items,
                         'shipped_at IS NULL OR (application_id IS NOT NULL AND ' \
                         "((fulfillment_source = 'direct_vendor' AND purchase_order_id IS NOT NULL) OR " \
                         "(fulfillment_source != 'direct_vendor' AND stock_received_on IS NOT NULL)))",
                         name: 'shipped_equipment_has_source'
    add_check_constraint :equipment_items,
                         'withdrawn_at IS NULL OR (shipped_at IS NULL AND ' \
                         "((fulfillment_source = 'direct_vendor' AND purchase_order_id IS NULL) OR " \
                         "(fulfillment_source != 'direct_vendor' AND application_id IS NULL)))",
                         name: 'withdrawn_equipment_source_resolved'
    add_check_constraint :equipment_items,
                         "fulfillment_source = 'direct_vendor' OR application_id IS NULL OR (stock_received_on IS NOT NULL AND stock_allocated_at IS NOT NULL)",
                         name: 'stock_allocation_received'
    add_check_constraint :equipment_items, "fulfillment_source != 'existing_stock' OR purchase_order_id IS NULL", name: 'existing_stock_no_po'
    %i[bid_groups purchase_orders].each do |table|
      add_check_constraint table, "purpose IN ('direct_to_constituents','program_stock')", name: "#{table}_purpose"
    end
    add_check_constraint :equipment_items,
                         "fulfillment_source = 'direct_vendor' OR ((application_id IS NULL) = (stock_allocated_at IS NULL))",
                         name: 'stock_allocation_beneficiary_paired'
    add_column :equipment_items, :unfulfilled_since, :datetime
  end
end
