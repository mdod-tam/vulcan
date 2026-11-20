# frozen_string_literal: true

class CreateIcanconnectSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :icanconnect_settings do |t|
      t.date :starts_on
      t.timestamps
      t.check_constraint 'id = 1', name: 'icanconnect_settings_singleton'
    end
  end
end
