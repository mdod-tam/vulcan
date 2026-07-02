# frozen_string_literal: true

class CoalesceDuplicatePendingRecoveryRequestsAndAddUniqueIndex < ActiveRecord::Migration[8.1]
  def up
    say_with_time 'Coalescing duplicate pending recovery requests' do
      execute <<~SQL.squish
        UPDATE recovery_requests
        SET status = 'rejected',
            resolved_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE id IN (
          SELECT id
          FROM (
            SELECT id,
                   ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at ASC, id ASC) AS row_num
            FROM recovery_requests
            WHERE status = 'pending'
          ) ranked
          WHERE row_num > 1
        )
      SQL
    end

    add_index :recovery_requests, :user_id,
              unique: true,
              where: "status = 'pending'",
              name: 'index_recovery_requests_one_pending_per_user'
  end

  def down
    remove_index :recovery_requests, name: 'index_recovery_requests_one_pending_per_user'
  end
end
