class AddLocationToTrainingSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :training_sessions, :location, :string
  end
end
