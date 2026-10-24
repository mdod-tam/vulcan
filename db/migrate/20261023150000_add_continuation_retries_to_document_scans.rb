# frozen_string_literal: true

class AddContinuationRetriesToDocumentScans < ActiveRecord::Migration[8.1]
  def change
    add_column :document_scans, :continuation_attempts, :integer, null: false, default: 0
    add_column :document_scans, :continuation_next_attempt_at, :datetime
    add_column :document_scans, :continuation_error_code, :string
    add_index :document_scans, %i[continuation continued_at continuation_next_attempt_at], name: :index_document_scans_on_continuation_recovery
  end
end
