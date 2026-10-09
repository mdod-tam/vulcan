# frozen_string_literal: true

class BindW9ReviewsToDocuments < ActiveRecord::Migration[8.1]
  def change
    add_reference :w9_reviews, :reviewed_blob, foreign_key: { to_table: :active_storage_blobs }
    add_index :w9_reviews, %i[vendor_id reviewed_blob_id], unique: true
    change_column_default :w9_reviews, :status, from: 0, to: nil
  end
end
