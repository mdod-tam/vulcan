# frozen_string_literal: true

class AddSyntaxToEmailTemplates < ActiveRecord::Migration[8.1]
  def change
    add_column :email_templates, :syntax, :integer, null: false, default: 0
  end
end
