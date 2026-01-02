# frozen_string_literal: true

class AddEnabledToEmailTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :email_templates, :enabled, :boolean, default: true, null: false
    add_index :email_templates, :enabled
  end
end
