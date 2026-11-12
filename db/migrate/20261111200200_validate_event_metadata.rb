# frozen_string_literal: true

class ValidateEventMetadata < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :events, name: 'events_metadata_object'
  end

  def down
    # PostgreSQL cannot unvalidate a check; recreate it in this transaction.
    remove_check_constraint :events, name: 'events_metadata_object'
    add_check_constraint :events, "jsonb_typeof(metadata) = 'object'", name: 'events_metadata_object', validate: false
  end
end
