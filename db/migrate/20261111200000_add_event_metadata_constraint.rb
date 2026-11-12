# frozen_string_literal: true

class AddEventMetadataConstraint < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :events, "jsonb_typeof(metadata) = 'object'", name: 'events_metadata_object', validate: false
  end
end
