# frozen_string_literal: true

class IndexEventHistoryMetadata < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    %w[application_id evaluation_id training_session_id].each do |key|
      add_index :events, "(metadata->>'#{key}')",
                name: "index_events_on_metadata_#{key}",
                where: "metadata->>'#{key}' IS NOT NULL", algorithm: :concurrently
    end
  end
end
