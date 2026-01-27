class RemoveCreatedByServiceFromNotifications < ActiveRecord::Migration[8.0]
  def change
    # Remove unused created_by_service column and index
    # This column was never set (only metadata was updated) and is not queried anywhere
    # All notifications go through NotificationService, making this redundant
    remove_index :notifications, :created_by_service, if_exists: true
    remove_column :notifications, :created_by_service, :boolean
  end
end
