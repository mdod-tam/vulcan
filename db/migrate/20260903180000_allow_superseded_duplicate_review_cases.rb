# frozen_string_literal: true

class AllowSupersededDuplicateReviewCases < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :duplicate_review_cases, name: 'duplicate_review_cases_status_check'
    add_check_constraint :duplicate_review_cases,
                         'status = ANY (ARRAY[0, 1, 2, 3, 4])',
                         name: 'duplicate_review_cases_status_check'
  end

  def down
    remove_check_constraint :duplicate_review_cases, name: 'duplicate_review_cases_status_check'
    add_check_constraint :duplicate_review_cases,
                         'status = ANY (ARRAY[0, 1, 2, 3])',
                         name: 'duplicate_review_cases_status_check'
  end
end
