# frozen_string_literal: true

require 'test_helper'
require Rails.root.join('db/migrate/20260709190000_replace_duplicate_review_resolution_with_workflow_state').to_s

class ReplaceDuplicateReviewResolutionWithWorkflowStateTest < ActiveSupport::TestCase
  TEST_TABLE = :duplicate_review_workflow_migration_examples

  EXPECTED_STATUSES = {
    'open' => 0,
    'approved_relationship' => 4,
    'approved_keep_separate' => 3,
    'approved_awaiting_information' => 1,
    'approved_security_review' => 2,
    'ignored_relationship' => 4,
    'ignored_keep_separate' => 3,
    'ignored_awaiting_information' => 1,
    'ignored_security_review' => 2,
    'merged_same_person' => 5,
    'approved_without_determination' => 4,
    'ignored_without_determination' => 3
  }.freeze

  setup do
    create_migration_test_table
    insert_historical_cases
  end

  teardown do
    connection.drop_table(TEST_TABLE, if_exists: true)
  end

  test 'maps every reachable coarse status and determination pair without losing review context' do
    ReplaceDuplicateReviewResolutionWithWorkflowState.new.send(:preserve_existing_review_context!, TEST_TABLE)

    rows = connection.select_all(<<~SQL.squish).index_by { |row| row.fetch('case_key') }
      SELECT case_key, status, reviewed_by_id, reviewed_at, resolved_by_id, resolved_at
      FROM #{connection.quote_table_name(TEST_TABLE)}
    SQL

    actual_statuses = rows.transform_values { |row| row.fetch('status').to_i }
    assert_equal EXPECTED_STATUSES, actual_statuses
    assert_equal 3, rows.fetch('approved_keep_separate').fetch('status').to_i

    rows.except('open').each_value do |row|
      assert_equal 42, row.fetch('reviewed_by_id')
      assert row.fetch('reviewed_at').present?

      if [1, 2].include?(row.fetch('status').to_i)
        assert_nil row.fetch('resolved_by_id')
        assert_nil row.fetch('resolved_at')
      else
        assert_equal 42, row.fetch('resolved_by_id')
        assert row.fetch('resolved_at').present?
      end
    end
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def create_migration_test_table
    connection.create_table(TEST_TABLE, temporary: true, force: true) do |table|
      table.string :case_key, null: false
      table.integer :status, null: false
      table.string :resolution_determination
      table.bigint :resolved_by_id
      table.datetime :resolved_at
      table.bigint :reviewed_by_id
      table.datetime :reviewed_at
    end
  end

  def insert_historical_cases
    values = [
      ['open', 0, nil, nil],
      ['approved_relationship', 1, 'authorized_relationship_confirmed', 42],
      ['approved_keep_separate', 1, 'keep_separate', 42],
      ['approved_awaiting_information', 1, 'needs_more_information', 42],
      ['approved_security_review', 1, 'fraud_or_security_review', 42],
      ['ignored_relationship', 2, 'authorized_relationship_confirmed', 42],
      ['ignored_keep_separate', 2, 'keep_separate', 42],
      ['ignored_awaiting_information', 2, 'needs_more_information', 42],
      ['ignored_security_review', 2, 'fraud_or_security_review', 42],
      ['merged_same_person', 3, 'same_person_confirmed', 42],
      ['approved_without_determination', 1, nil, 42],
      ['ignored_without_determination', 2, nil, 42]
    ]
    quoted_values = values.map do |case_key, status, determination, actor_id|
      resolved_at = actor_id ? connection.quote(Time.zone.parse('2026-07-09 12:00:00')) : 'NULL'
      "(#{connection.quote(case_key)}, #{status}, #{connection.quote(determination)}, " \
        "#{actor_id || 'NULL'}, #{resolved_at})"
    end

    connection.execute <<~SQL.squish
      INSERT INTO #{connection.quote_table_name(TEST_TABLE)}
        (case_key, status, resolution_determination, resolved_by_id, resolved_at)
      VALUES #{quoted_values.join(', ')}
    SQL
  end
end
