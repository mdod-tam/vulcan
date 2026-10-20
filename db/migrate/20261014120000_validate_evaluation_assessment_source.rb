# frozen_string_literal: true

class ValidateEvaluationAssessmentSource < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :evaluations, name: 'evaluation_assessment_source'
  end

  def down
    # PostgreSQL cannot unvalidate a check; recreate it in this transaction.
    remove_check_constraint :evaluations, name: 'evaluation_assessment_source'
    add_check_constraint :evaluations, "assessment_source IN ('direct_assessment', 'outside_specialist')",
                         name: 'evaluation_assessment_source', validate: false
  end
end
