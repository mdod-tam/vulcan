# frozen_string_literal: true

# These solid_queue tables were incorrectly created in the primary database.
# Solid Queue is configured to use a separate 'queue' database, so these
# tables in the primary DB are unused orphans. This migration removes them.
#
# The correct solid_queue tables exist in mat_vulcan_queue_development (dev)
# and the QUEUE_DATABASE_URL database (production).
class RemoveOrphanedSolidQueueTablesFromPrimary < ActiveRecord::Migration[8.0]
  def up
    # Only run on primary database - skip if somehow run on queue database
    return if connection.current_database.include?('queue')

    # Drop in correct order to avoid foreign key violations
    drop_table :solid_queue_recurring_executions, if_exists: true
    drop_table :solid_queue_scheduled_executions, if_exists: true
    drop_table :solid_queue_ready_executions, if_exists: true
    drop_table :solid_queue_claimed_executions, if_exists: true
    drop_table :solid_queue_blocked_executions, if_exists: true
    drop_table :solid_queue_failed_executions, if_exists: true
    drop_table :solid_queue_semaphores, if_exists: true
    drop_table :solid_queue_pauses, if_exists: true
    drop_table :solid_queue_recurring_tasks, if_exists: true
    drop_table :solid_queue_processes, if_exists: true
    drop_table :solid_queue_jobs, if_exists: true
    drop_table :solid_queue_tables, if_exists: true
  end

  def down
    # Intentionally left empty - we don't want to recreate these orphan tables.
    # If needed, run the solid_queue installation generator against the queue database.
    raise ActiveRecord::IrreversibleMigration,
          'This migration removes orphaned tables. Run solid_queue:install on the queue database instead.'
  end
end
