# frozen_string_literal: true

class CreateDuplicateReviewCases < ActiveRecord::Migration[8.1]
  OPEN_STATUS = 0
  ALLOWED_STATUSES = [0, 1, 2, 3].freeze

  def up
    create_table :duplicate_review_cases do |t|
      t.integer :status, null: false, default: OPEN_STATUS
      t.integer :source, null: false
      t.references :subject_user, null: true, foreign_key: { to_table: :users }
      t.string :subject_fingerprint
      t.string :deduplication_key, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :opened_at, null: false
      t.datetime :resolved_at
      t.references :resolved_by, null: true, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_check_constraint :duplicate_review_cases,
                         "status IN (#{ALLOWED_STATUSES.join(', ')})",
                         name: 'duplicate_review_cases_status_check'

    add_index :duplicate_review_cases, :deduplication_key,
              unique: true,
              where: "status = #{OPEN_STATUS}",
              name: 'index_duplicate_review_cases_open_deduplication_key'

    add_index :duplicate_review_cases, :status
    add_index :duplicate_review_cases, :source

    create_table :duplicate_review_case_candidates do |t|
      t.references :duplicate_review_case, null: false, foreign_key: true
      t.references :candidate_user, null: true, foreign_key: { to_table: :users }
      t.string :match_reason, null: false
      t.jsonb :snapshot, null: false, default: {}

      t.timestamps
    end

    add_index :duplicate_review_case_candidates,
              %i[duplicate_review_case_id candidate_user_id match_reason],
              unique: true,
              name: 'index_duplicate_review_case_candidates_unique_match'
  end

  def down
    drop_table :duplicate_review_case_candidates
    drop_table :duplicate_review_cases
  end
end
