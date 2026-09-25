# frozen_string_literal: true

class AddAutosaveRevisionsToApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :applications, :autosave_revisions, :jsonb, default: {}, null: false
  end
end
