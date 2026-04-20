# frozen_string_literal: true

class AddTrainingRequestedAtToApplications < ActiveRecord::Migration[8.0]
  def change
    add_column :applications, :training_requested_at, :datetime
    add_index :applications, :training_requested_at
  end
end
