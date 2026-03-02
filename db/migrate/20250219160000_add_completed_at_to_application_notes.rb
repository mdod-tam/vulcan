# frozen_string_literal: true

class AddCompletedAtToApplicationNotes < ActiveRecord::Migration[7.1]
  def change
    add_column :application_notes, :completed_at, :datetime
    add_index :application_notes, :completed_at
  end
end
