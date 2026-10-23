# frozen_string_literal: true

class AddCreatedAtIndexToDocumentScans < ActiveRecord::Migration[8.1]
  def change
    add_index :document_scans, :created_at
  end
end
