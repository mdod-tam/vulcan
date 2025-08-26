# frozen_string_literal: true

class WidenPrintQueueLetterTypeCheck < ActiveRecord::Migration[8.0]
  CONSTRAINT_NAME = :check_print_queue_items_on_letter_type

  def up
    # Replace the existing constraint (0..10) with an updated one (0..11)
    remove_check_constraint :print_queue_items, name: CONSTRAINT_NAME, if_exists: true
    add_check_constraint :print_queue_items,
                         'letter_type >= 0 AND letter_type <= 11',
                         name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :print_queue_items, name: CONSTRAINT_NAME, if_exists: true
    add_check_constraint :print_queue_items,
                         'letter_type >= 0 AND letter_type <= 10',
                         name: CONSTRAINT_NAME
  end
end
