# frozen_string_literal: true

# Brings the tables created by 20251203000001 in line with the Solid Queue gem's own schema
# (solid_queue 1.7, lib/generators/solid_queue/install/templates/db/queue_schema.rb):
# - drops solid_queue_tables, which Solid Queue never defined;
# - drops the failed_executions columns, indexes, and process foreign key that application
#   migrations added in 2025, keeping every failure row;
# - restores the unique failed_executions.job_id index. Job#failed_with rescues RecordNotUnique
#   to update the existing failure, so it depends on the constraint.
# Queued jobs are not touched.
class AlignSolidQueueSchemaWithGem < ActiveRecord::Migration[8.1]
  JOB_ID_INDEX = 'index_solid_queue_failed_executions_on_job_id'

  def up
    ensure_one_failure_per_job
    drop_table :solid_queue_tables, if_exists: true
    drop_custom_failure_structure
    add_index :solid_queue_failed_executions, :job_id, unique: true, name: JOB_ID_INDEX
  end

  def down
    create_table :solid_queue_tables do |t|
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
    end
    remove_index :solid_queue_failed_executions, name: JOB_ID_INDEX
    restore_custom_failure_structure
  end

  private

  def ensure_one_failure_per_job
    repeated = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM (
        SELECT job_id FROM solid_queue_failed_executions GROUP BY job_id HAVING COUNT(*) > 1
      ) AS repeated_jobs
    SQL
    return if repeated.zero?

    raise "#{repeated} job(s) have more than one solid_queue_failed_executions row; " \
          'keep one row per job_id, then rerun this migration'
  end

  # Dropping a column drops the index on it, so only the job_id index and the foreign key need naming.
  def drop_custom_failure_structure
    remove_foreign_key :solid_queue_failed_executions, column: :process_id
    remove_index :solid_queue_failed_executions, name: JOB_ID_INDEX
    %i[backtrace failed_at process_id updated_at].each do |column|
      remove_column :solid_queue_failed_executions, column
    end
  end

  def restore_custom_failure_structure
    add_column :solid_queue_failed_executions, :process_id, :bigint
    add_column :solid_queue_failed_executions, :backtrace, :text
    add_column :solid_queue_failed_executions, :failed_at, :datetime, default: -> { 'CURRENT_TIMESTAMP' }, null: false
    # The default fills existing rows; the original column had none.
    add_column :solid_queue_failed_executions, :updated_at, :datetime, default: -> { 'CURRENT_TIMESTAMP' }, null: false
    change_column_default :solid_queue_failed_executions, :updated_at, nil
    add_index :solid_queue_failed_executions, :failed_at
    add_index :solid_queue_failed_executions, :job_id
    add_index :solid_queue_failed_executions, :process_id
    add_foreign_key :solid_queue_failed_executions, :solid_queue_processes, column: :process_id, on_delete: :nullify
  end
end
