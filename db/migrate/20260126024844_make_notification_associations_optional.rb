class MakeNotificationAssociationsOptional < ActiveRecord::Migration[8.0]
  def change
    # The model declares actor and notifiable optional; system notifications have neither.
    change_column_null :notifications, :actor_id, true
    change_column_null :notifications, :notifiable_id, true
  end
end
