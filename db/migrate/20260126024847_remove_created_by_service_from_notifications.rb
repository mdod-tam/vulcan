class RemoveCreatedByServiceFromNotifications < ActiveRecord::Migration[8.0]
  def change
    # created_by_service was never set and is not queried.
    remove_index :notifications, :created_by_service, if_exists: true
    remove_column :notifications, :created_by_service, :boolean
  end
end
