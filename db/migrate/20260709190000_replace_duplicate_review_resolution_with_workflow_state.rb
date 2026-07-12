# frozen_string_literal: true

class ReplaceDuplicateReviewResolutionWithWorkflowState < ActiveRecord::Migration[8.1]
  OLD_DEDUPLICATION_INDEX = 'index_duplicate_review_cases_open_deduplication_key'
  PENDING_DEDUPLICATION_INDEX = 'index_duplicate_review_cases_pending_deduplication_key'
  STATUS_CONSTRAINT = 'duplicate_review_cases_status_check'

  def up
    remove_index :duplicate_review_cases, name: OLD_DEDUPLICATION_INDEX
    remove_check_constraint :duplicate_review_cases, name: STATUS_CONSTRAINT

    rename_column :duplicate_review_cases, :resolution_rationale, :review_rationale
    rename_column :duplicate_review_cases, :resolution_metadata, :review_metadata
    add_reference :duplicate_review_cases, :reviewed_by, foreign_key: { to_table: :users }
    add_column :duplicate_review_cases, :reviewed_at, :datetime

    preserve_existing_review_context!
    remove_column :duplicate_review_cases, :resolution_determination, :string

    add_check_constraint :duplicate_review_cases,
                         'status = ANY (ARRAY[0, 1, 2, 3, 4, 5])',
                         name: STATUS_CONSTRAINT
    add_index :duplicate_review_cases,
              :deduplication_key,
              unique: true,
              where: 'status IN (0, 1, 2)',
              name: PENDING_DEDUPLICATION_INDEX
  end

  def down
    remove_current_deduplication_index
    remove_check_constraint :duplicate_review_cases, name: STATUS_CONSTRAINT

    add_column :duplicate_review_cases, :resolution_determination, :string
    restore_coarse_resolution_context!

    remove_reference :duplicate_review_cases, :reviewed_by, foreign_key: { to_table: :users }
    remove_column :duplicate_review_cases, :reviewed_at, :datetime
    rename_column :duplicate_review_cases, :review_rationale, :resolution_rationale
    rename_column :duplicate_review_cases, :review_metadata, :resolution_metadata

    add_check_constraint :duplicate_review_cases,
                         'status = ANY (ARRAY[0, 1, 2, 3])',
                         name: STATUS_CONSTRAINT
    add_index :duplicate_review_cases,
              :deduplication_key,
              unique: true,
              where: 'status = 0',
              name: OLD_DEDUPLICATION_INDEX
  end

  private

  def remove_current_deduplication_index
    index_name = if index_name_exists?(:duplicate_review_cases, PENDING_DEDUPLICATION_INDEX)
                   PENDING_DEDUPLICATION_INDEX
                 else
                   OLD_DEDUPLICATION_INDEX
                 end
    remove_index :duplicate_review_cases, name: index_name
  end

  def preserve_existing_review_context!(table_name = :duplicate_review_cases)
    quoted_table = quote_table_name(table_name)

    execute <<~SQL.squish
      UPDATE #{quoted_table}
      SET reviewed_by_id = resolved_by_id,
          reviewed_at = resolved_at,
          status = CASE
            WHEN status = 3 THEN 5
            WHEN resolution_determination = 'needs_more_information' THEN 1
            WHEN resolution_determination = 'fraud_or_security_review' THEN 2
            WHEN resolution_determination = 'authorized_relationship_confirmed' THEN 4
            WHEN resolution_determination = 'same_person_confirmed' THEN 5
            WHEN resolution_determination = 'keep_separate' THEN 3
            WHEN status = 1 THEN 4
            WHEN status = 2 THEN 3
            ELSE status
          END
    SQL

    execute <<~SQL.squish
      UPDATE #{quoted_table}
      SET resolved_by_id = NULL,
          resolved_at = NULL
      WHERE status IN (0, 1, 2)
    SQL
  end

  def restore_coarse_resolution_context!
    execute <<~SQL.squish
      UPDATE duplicate_review_cases
      SET resolution_determination = CASE status
            WHEN 1 THEN 'needs_more_information'
            WHEN 2 THEN 'fraud_or_security_review'
            WHEN 3 THEN 'keep_separate'
            WHEN 4 THEN 'authorized_relationship_confirmed'
            WHEN 5 THEN 'same_person_confirmed'
          END,
          status = CASE
            WHEN status IN (1, 2) THEN 0
            WHEN status = 3 THEN 2
            WHEN status = 4 THEN 1
            WHEN status = 5 THEN 3
            ELSE status
          END
    SQL
  end
end
