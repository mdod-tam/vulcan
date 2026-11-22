# frozen_string_literal: true

class CatalogAndFulfillmentDefaults < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :category, :string, null: false, default: 'devices'
    add_column :products, :eligible_disability_groups, :text, array: true, null: false, default: []
    add_column :products, :catalog_key, :string
    add_column :products, :model_confirmed, :boolean, null: false, default: false
    add_column :products, :manufacturer_model_identity, :string
    add_index :products, :catalog_key, unique: true
    add_index :products, :manufacturer_model_identity, unique: true, where: 'model_confirmed = TRUE', name: 'index_products_on_confirmed_model_identity'
    add_check_constraint :products, 'NOT model_confirmed OR manufacturer_model_identity IS NOT NULL', name: 'products_confirmed_identity_present'

    add_column :applications, :program_disability_groups, :text, array: true, null: false, default: []
    %i[shipping_care_of shipping_address_1 shipping_address_2 shipping_city shipping_state shipping_zip_code].each do |field|
      add_column :applications, field, :text
    end
    add_column :applications, :equipment_needs_decided_at, :datetime
    drop_table :products_users, id: false do |t|
      t.bigint :product_id, null: false
      t.bigint :user_id, null: false
      t.index :product_id
      t.index :user_id
    end
    add_column :products, :msrp, :decimal, precision: 12, scale: 2
    add_check_constraint :products, 'msrp IS NULL OR msrp >= 0', name: 'products_msrp_nonnegative'
  end
end
