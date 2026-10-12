# frozen_string_literal: true

class AddCompletionTimestampsToEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_column :evaluations, :appointment_completed_at, :datetime
    add_column :evaluations, :report_submitted_at, :datetime
  end
end
