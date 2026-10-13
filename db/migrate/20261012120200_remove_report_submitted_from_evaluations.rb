# frozen_string_literal: true

class RemoveReportSubmittedFromEvaluations < ActiveRecord::Migration[8.1]
  def change
    remove_column :evaluations, :report_submitted, :boolean
  end
end
