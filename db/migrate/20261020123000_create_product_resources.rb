# frozen_string_literal: true

class CreateProductResources < ActiveRecord::Migration[8.1]
  def change
    create_table :product_resources do |t|
      t.references :product, null: false, foreign_key: true
      t.string :title, null: false
      t.string :locale, null: false
      t.text :url
      t.timestamps
    end
    add_index :product_resources, %i[product_id locale]
  end
end
