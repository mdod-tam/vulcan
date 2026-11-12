# frozen_string_literal: true

class ValidateEventMetadata < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :events, "jsonb_typeof(metadata) = 'object'", name: 'events_metadata_object'
  end
end
