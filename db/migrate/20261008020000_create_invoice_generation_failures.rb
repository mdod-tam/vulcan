# frozen_string_literal: true

# A vendor whose automatic invoicing failed, so staff can see it and retry. One unresolved row per
# vendor at most; a later successful run marks it resolved.
class CreateInvoiceGenerationFailures < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_generation_failures do |t|
      t.references :vendor, null: false, foreign_key: { to_table: :users }
      t.datetime :attempted_at, null: false
      t.datetime :cutoff, null: false
      t.string :error_category, null: false
      t.integer :attempts, null: false, default: 1
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :invoice_generation_failures, :vendor_id, unique: true, where: 'resolved_at IS NULL',
                                                        name: 'index_unresolved_invoice_generation_failures'
  end
end
