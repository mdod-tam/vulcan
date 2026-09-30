# frozen_string_literal: true

class AddEmailDeliveryPollIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :email_delivery_attempts, %i[server_id last_checked_at id],
              name: 'index_email_delivery_attempts_on_pollable',
              order: { last_checked_at: 'ASC NULLS FIRST' },
              where: 'delivered_at IS NULL AND bounced_at IS NULL AND complained_at IS NULL ' \
                     "AND state <> 'failed' AND provider_message_id IS NOT NULL AND check_count < 8",
              algorithm: :concurrently
  end
end
