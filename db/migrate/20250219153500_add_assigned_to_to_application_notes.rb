# frozen_string_literal: true

class AddAssignedToToApplicationNotes < ActiveRecord::Migration[7.1]
  def change
    add_column :application_notes, :assigned_to_id, :bigint
    add_index :application_notes, :assigned_to_id
    add_foreign_key :application_notes, :users, column: :assigned_to_id
  end
end
