class AddPreferredMeansOfCommunicationToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :preferred_means_of_communication, :string unless column_exists?(:users, :preferred_means_of_communication)
  end
end
