# frozen_string_literal: true

class AddEmailTemplateSnapshots < ActiveRecord::Migration[8.1]
  def change
    rename_column :email_templates, :needs_sync, :locale_needs_sync

    create_table :email_template_snapshots do |t|
      t.references :email_template, null: false, foreign_key: true
      t.integer :snapshot_number, null: false
      t.string :change_source, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.jsonb :variables, null: false, default: {}
      t.integer :format, null: false, default: 1
      t.string :locale, null: false, default: 'en'
      t.boolean :enabled, null: false, default: true
      t.text :description, null: false
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :email_template_snapshots,
              %i[email_template_id snapshot_number],
              unique: true,
              name: 'index_email_template_snapshots_on_template_and_number'
  end
end
