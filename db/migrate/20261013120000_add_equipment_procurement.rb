# frozen_string_literal: true

class AddEquipmentProcurement < ActiveRecord::Migration[8.1]
  def change
    add_column :applications, :equipment_needs_initialized_at, :datetime
    add_column :evaluations, :assessment_source, :string, null: false, default: 'direct_assessment'
    add_check_constraint :evaluations, "assessment_source IN ('direct_assessment', 'outside_specialist')",
                         name: 'evaluation_assessment_source', validate: false

    create_table :equipment_needs do |t|
      t.references :application, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.references :source_evaluation, foreign_key: { to_table: :evaluations }
      t.integer :remaining_quantity, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :equipment_needs, %i[application_id product_id], unique: true
    add_check_constraint :equipment_needs, 'remaining_quantity >= 0', name: 'equipment_need_quantity'

    create_table :purchase_orders do |t|
      t.references :vendor, null: false, foreign_key: { to_table: :users }
      t.string :number, null: false
      t.string :normalized_number, null: false
      t.date :sent_at, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :purchase_orders, %i[vendor_id normalized_number], unique: true

    create_table :equipment_items do |t|
      t.references :application, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.references :purchase_order, foreign_key: true
      t.references :source_evaluation, foreign_key: { to_table: :evaluations }
      t.date :shipped_at
      t.string :carrier
      t.text :tracking_number
      t.text :serial_number
      t.text :imei
      t.text :normalized_imei
      t.text :normalized_serial_number
      t.string :manufacturer_model_identity, null: false
      t.string :normalized_manufacturer, null: false
      t.datetime :withdrawn_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :equipment_items, :normalized_imei,
              unique: true, where: 'withdrawn_at IS NULL AND normalized_imei IS NOT NULL', name: 'active_equipment_imei'
    add_index :equipment_items, %i[manufacturer_model_identity normalized_serial_number],
              unique: true, where: 'withdrawn_at IS NULL AND normalized_serial_number IS NOT NULL', name: 'active_equipment_model_serial'
    add_check_constraint :equipment_items, 'shipped_at IS NULL OR purchase_order_id IS NOT NULL', name: 'shipped_equipment_has_po'
    add_check_constraint :equipment_items, 'withdrawn_at IS NULL OR (purchase_order_id IS NULL AND shipped_at IS NULL)', name: 'withdrawn_equipment_detached'
  end
end
