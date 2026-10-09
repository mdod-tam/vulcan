# frozen_string_literal: true

class ProtectBusinessTaxIds < ActiveRecord::Migration[8.1]
  def up
    remove_index :users, :business_tax_id
    change_column :users, :business_tax_id, :text
  end

  def down
    change_column :users, :business_tax_id, :string
    add_index :users, :business_tax_id
  end
end
