# frozen_string_literal: true

class AddUniquePendingRecoveryRequestIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :recovery_requests, :user_id,
              unique: true,
              where: "status = 'pending'",
              name: 'index_recovery_requests_one_pending_per_user'
  end
end
