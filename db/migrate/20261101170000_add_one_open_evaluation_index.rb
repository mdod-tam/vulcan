# frozen_string_literal: true

class AddOneOpenEvaluationIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Evaluation.open_assigned includes no-show and rescheduled work, unlike training's open predicate.
    add_index :evaluations, :application_id, unique: true,
                                             where: 'status NOT IN (3, 4)', name: 'index_evaluations_one_open_per_application', algorithm: :concurrently
  end
end
