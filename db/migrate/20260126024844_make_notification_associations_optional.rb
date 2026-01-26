class MakeNotificationAssociationsOptional < ActiveRecord::Migration[8.0]
  def change
    # Remove NOT NULL constraints to allow optional actor and notifiable associations
    # This aligns the database schema with the model's `optional: true` declarations
    # and allows for system notifications that don't require a specific actor or notifiable
    change_column_null :notifications, :actor_id, true
    change_column_null :notifications, :notifiable_id, true
  end
end
