# frozen_string_literal: true

class AddOneOpenTrainingSessionIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_training_sessions_one_open_per_application'
  # TrainingSession statuses: requested: 0, scheduled: 1, confirmed: 2.
  OPEN_STATUS_SQL = 'status IN (0, 1, 2)'

  def up
    duplicate_rows = select_all(<<~SQL.squish)
      SELECT application_id, COUNT(*) AS open_count
      FROM training_sessions
      WHERE #{OPEN_STATUS_SQL}
      GROUP BY application_id
      HAVING COUNT(*) > 1
    SQL

    if duplicate_rows.any?
      application_ids = duplicate_rows.map { |row| row['application_id'] }.join(', ')
      raise "Cannot add #{INDEX_NAME}; duplicate open training sessions exist for application IDs: #{application_ids}"
    end

    mutated_history_rows = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM training_sessions
      WHERE status IN (1, 2)
        AND (cancelled_at IS NOT NULL OR cancellation_reason IS NOT NULL OR no_show_notes IS NOT NULL)
    SQL
    say "#{mutated_history_rows} scheduled/confirmed training sessions have historical cancellation/no-show fields set.", true if mutated_history_rows.positive?

    add_index :training_sessions,
              :application_id,
              unique: true,
              where: OPEN_STATUS_SQL,
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :training_sessions, name: INDEX_NAME, algorithm: :concurrently
  end
end
