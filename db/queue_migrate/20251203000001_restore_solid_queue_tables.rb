# frozen_string_literal: true

# Restore Solid Queue tables that were incorrectly removed in migration
# 20251202000001_remove_orphaned_solid_queue_tables_from_primary.
#
# The tables were NOT orphaned - they were being used and their absence c
# causes Heroku to throw errors
class RestoreSolidQueueTables < ActiveRecord::Migration[8.0]
  def change # rubocop:disable Metrics/MethodLength
    # Core jobs table
    create_table :solid_queue_jobs do |t|
      t.string :queue_name, null: false
      t.string :class_name, null: false
      t.text :arguments
      t.integer :priority, default: 0, null: false
      t.string :active_job_id
      t.datetime :scheduled_at
      t.datetime :finished_at
      t.string :concurrency_key
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index :active_job_id
      t.index :class_name
      t.index :finished_at
      t.index %i[queue_name finished_at], name: 'index_solid_queue_jobs_for_filtering'
      t.index %i[scheduled_at finished_at], name: 'index_solid_queue_jobs_for_alerting'
    end

    # Processes table
    create_table :solid_queue_processes do |t|
      t.string :kind, null: false
      t.datetime :last_heartbeat_at, null: false
      t.bigint :supervisor_id
      t.integer :pid, null: false
      t.string :hostname
      t.text :metadata
      t.datetime :created_at, null: false
      t.string :name, null: false

      t.index :last_heartbeat_at
      t.index %i[name supervisor_id], unique: true
      t.index :supervisor_id
    end

    # Blocked executions
    create_table :solid_queue_blocked_executions do |t|
      t.bigint :job_id, null: false
      t.string :queue_name, null: false
      t.integer :priority, default: 0, null: false
      t.string :concurrency_key, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false

      t.index %i[concurrency_key priority job_id], name: 'index_solid_queue_blocked_executions_for_release'
      t.index %i[expires_at concurrency_key], name: 'index_solid_queue_blocked_executions_for_maintenance'
      t.index :job_id, unique: true
    end

    # Claimed executions
    create_table :solid_queue_claimed_executions do |t|
      t.bigint :job_id, null: false
      t.bigint :process_id
      t.datetime :created_at, null: false

      t.index :job_id, unique: true
      t.index %i[process_id job_id]
    end

    # Failed executions
    create_table :solid_queue_failed_executions do |t|
      t.bigint :job_id, null: false
      t.bigint :process_id
      t.text :error
      t.text :backtrace
      t.datetime :failed_at, default: -> { 'CURRENT_TIMESTAMP' }, null: false
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index :failed_at
      t.index :job_id
      t.index :process_id
    end

    # Pauses
    create_table :solid_queue_pauses do |t|
      t.string :queue_name, null: false
      t.datetime :created_at, null: false

      t.index :queue_name, unique: true
    end

    # Ready executions
    create_table :solid_queue_ready_executions do |t|
      t.bigint :job_id, null: false
      t.string :queue_name, null: false
      t.integer :priority, default: 0, null: false
      t.datetime :created_at, null: false

      t.index :job_id, unique: true
      t.index %i[priority job_id], name: 'index_solid_queue_poll_all'
      t.index %i[queue_name priority job_id], name: 'index_solid_queue_poll_by_queue'
    end

    # Recurring executions
    create_table :solid_queue_recurring_executions do |t|
      t.bigint :job_id, null: false
      t.string :task_key, null: false
      t.datetime :run_at, null: false
      t.datetime :created_at, null: false

      t.index :job_id, unique: true
      t.index %i[task_key run_at], unique: true
    end

    # Recurring tasks
    create_table :solid_queue_recurring_tasks do |t|
      t.string :key, null: false
      t.string :schedule, null: false
      t.string :command, limit: 2048
      t.string :class_name
      t.text :arguments
      t.string :queue_name
      t.integer :priority, default: 0
      t.boolean :static, default: true, null: false
      t.text :description
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index :key, unique: true
      t.index :static
    end

    # Scheduled executions
    create_table :solid_queue_scheduled_executions do |t|
      t.bigint :job_id, null: false
      t.string :queue_name, null: false
      t.integer :priority, default: 0, null: false
      t.datetime :scheduled_at, null: false
      t.datetime :created_at, null: false

      t.index :job_id, unique: true
      t.index %i[scheduled_at priority job_id], name: 'index_solid_queue_dispatch_all'
    end

    # Semaphores
    create_table :solid_queue_semaphores do |t|
      t.string :key, null: false
      t.integer :value, default: 1, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index :expires_at
      t.index %i[key value]
      t.index :key, unique: true
    end

    # Marker table (used by Solid Queue internally)
    create_table :solid_queue_tables do |t|
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
    end

    # Foreign keys
    add_foreign_key :solid_queue_blocked_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    add_foreign_key :solid_queue_claimed_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    add_foreign_key :solid_queue_failed_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    add_foreign_key :solid_queue_failed_executions, :solid_queue_processes, column: :process_id, on_delete: :nullify
    add_foreign_key :solid_queue_ready_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    add_foreign_key :solid_queue_recurring_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
    add_foreign_key :solid_queue_scheduled_executions, :solid_queue_jobs, column: :job_id, on_delete: :cascade
  end
end
