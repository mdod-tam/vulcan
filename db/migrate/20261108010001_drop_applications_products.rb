# frozen_string_literal: true

class DropApplicationsProducts < ActiveRecord::Migration[8.0]
  def change
    drop_table :applications_products, id: false do |t|
      t.bigint :application_id, null: false
      t.bigint :product_id, null: false
      t.index %i[application_id product_id], name: 'index_applications_products_on_application_id_and_product_id'
      t.index %i[product_id application_id], name: 'index_applications_products_on_product_id_and_application_id'
    end
  end
end
