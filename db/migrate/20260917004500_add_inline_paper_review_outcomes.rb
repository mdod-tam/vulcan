# frozen_string_literal: true

class AddInlinePaperReviewOutcomes < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :duplicate_review_cases, name: 'duplicate_review_cases_status_check'
    add_check_constraint :duplicate_review_cases, 'status IN (0, 1, 2, 3, 4, 5)', name: 'duplicate_review_cases_status_check'
    add_index :duplicate_review_cases, :deduplication_key,
              unique: true,
              where: "source = 1 AND metadata->>'intake_context' IN ('paper_inline_keep_separate', 'paper_inline_selection')",
              name: 'index_inline_paper_review_decisions_unique'
  end

  def down
    remove_index :duplicate_review_cases, name: 'index_inline_paper_review_decisions_unique'
    remove_check_constraint :duplicate_review_cases, name: 'duplicate_review_cases_status_check'
    add_check_constraint :duplicate_review_cases, 'status IN (0, 1, 2, 3, 4)', name: 'duplicate_review_cases_status_check'
  end
end
