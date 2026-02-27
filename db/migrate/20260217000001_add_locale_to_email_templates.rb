# frozen_string_literal: true

class AddLocaleToEmailTemplates < ActiveRecord::Migration[8.0]
  def up
    add_column :email_templates, :locale, :string, null: false, default: 'en'
    add_column :email_templates, :needs_sync, :boolean, null: false, default: false

    remove_index :email_templates, name: 'index_email_templates_on_name'
    add_index :email_templates, %i[name format locale], unique: true,
                                                        name: 'index_email_templates_on_name_format_locale'
  end

  def down
    remove_index :email_templates, name: 'index_email_templates_on_name_format_locale'
    add_index :email_templates, :name, unique: true, name: 'index_email_templates_on_name'

    remove_column :email_templates, :needs_sync
    remove_column :email_templates, :locale
  end
end
