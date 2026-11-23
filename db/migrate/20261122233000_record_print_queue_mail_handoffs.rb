# frozen_string_literal: true

class RecordPrintQueueMailHandoffs < ActiveRecord::Migration[8.1]
  def change
    add_column :print_queue_items, :mail_handoff_at, :datetime
    add_reference :print_queue_items, :mail_handoff_by, foreign_key: { to_table: :users }
    add_column :print_queue_items, :mail_discarded_at, :datetime
    add_column :print_queue_items, :follow_up_closed_at, :datetime
  end
end
