# frozen_string_literal: true

class CreateDocumentStorageDeletions < ActiveRecord::Migration[8.1]
  def change
    create_table :document_storage_deletions do |t|
      t.string :key, null: false, index: { unique: true }
      t.string :service_name, null: false
      t.string :content_type
      t.timestamps
    end
  end
end
