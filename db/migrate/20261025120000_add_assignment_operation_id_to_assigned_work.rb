# frozen_string_literal: true

class AddAssignmentOperationIdToAssignedWork < ActiveRecord::Migration[8.1]
  def change
    # The assignment write that last gave the row to its assignee. A queued notice names its operation,
    # so a later transfer supersedes it even when the same person holds the work again.
    add_column :evaluations, :assignment_operation_id, :string
    add_column :training_sessions, :assignment_operation_id, :string
  end
end
