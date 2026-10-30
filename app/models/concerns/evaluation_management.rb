# frozen_string_literal: true

# Evaluation lookups for an application. Applications::EvaluatorAssignment owns assigning and transferring evaluators.
module EvaluationManagement
  extend ActiveSupport::Concern

  # The evaluation still owed to the constituent: neither completed nor cancelled.
  def open_evaluation
    evaluations.open_assigned.order(:id).last
  end

  def latest_evaluation
    evaluations.order(created_at: :desc).first
  end

  def last_evaluation_completed_at
    evaluations.where(status: :completed).order(evaluation_date: :desc).limit(1).pick(:evaluation_date)
  end

  # Newest first.
  def all_evaluations
    evaluations.order(created_at: :desc)
  end
end
