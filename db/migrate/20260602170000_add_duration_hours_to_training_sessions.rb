# frozen_string_literal: true

class AddDurationHoursToTrainingSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :training_sessions, :duration_hours, :decimal, precision: 5, scale: 2, default: 2.0, null: false
  end
end
