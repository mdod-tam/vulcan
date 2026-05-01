# frozen_string_literal: true

class AddCancellationInitiatorToTrainingSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :training_sessions, :cancellation_initiator, :integer
  end
end
