# frozen_string_literal: true

class RemoveOneOpenTrainingSessionIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_training_sessions_one_open_per_application'
  OPEN_STATUS_SQL = 'status IN (0, 1, 2)'

  def up
    remove_index :training_sessions, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :training_sessions,
              :application_id,
              unique: true,
              where: OPEN_STATUS_SQL,
              name: INDEX_NAME,
              algorithm: :concurrently,
              if_not_exists: true
  end
end
