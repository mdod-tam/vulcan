# frozen_string_literal: true

class CreateDocumentScanProviderBudgets < ActiveRecord::Migration[8.1]
  def change
    create_table :document_scan_provider_budgets do |t|
      t.datetime :next_available_at, null: false
      t.timestamps
    end
    add_check_constraint :document_scan_provider_budgets, 'id = 1', name: 'document_scan_provider_budget_singleton'
  end
end
