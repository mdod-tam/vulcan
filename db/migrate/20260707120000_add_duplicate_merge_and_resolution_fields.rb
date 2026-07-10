# frozen_string_literal: true

# Durable duplicate-review resolution fields plus user merge-retirement metadata.
# A merged duplicate is deactivated and points at its canonical survivor; it is never destroyed.
class AddDuplicateMergeAndResolutionFields < ActiveRecord::Migration[8.1]
  def change
    add_column :duplicate_review_cases, :resolution_determination, :string
    add_column :duplicate_review_cases, :resolution_rationale, :text
    add_column :duplicate_review_cases, :resolution_metadata, :jsonb, null: false, default: {}

    add_reference :users, :merged_into_user, null: true, foreign_key: { to_table: :users }
    add_reference :users, :merged_by, null: true, foreign_key: { to_table: :users }
    add_column :users, :merged_at, :datetime
  end
end
