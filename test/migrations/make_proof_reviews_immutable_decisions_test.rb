# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/migrate/20261111110000_make_proof_reviews_immutable_decisions'

class MakeProofReviewsImmutableDecisionsTest < ActiveSupport::TestCase
  setup do
    @connection = ActiveRecord::Base.connection
    @connection.create_table(:proof_reviews, temporary: true) do |table|
      table.bigint :application_id, null: false
      table.bigint :admin_id, null: false
      table.integer :proof_type
      table.integer :status
      table.datetime :reviewed_at, null: false
      table.text :notes
    end
    @migration = MakeProofReviewsImmutableDecisions.new
  end

  teardown do
    @connection.execute('DROP TABLE IF EXISTS pg_temp.proof_reviews')
  end

  test 'preserves populated review history and requires decision fields for new rows' do
    @connection.execute(<<~SQL.squish)
      INSERT INTO proof_reviews (id, application_id, admin_id, proof_type, status, reviewed_at, notes)
      VALUES (1, 3, 7, 0, 0, '2026-10-10 12:00:00', NULL),
             (2, 3, 8, 0, 1, '2026-10-11 13:00:00', 'Review note')
    SQL
    original = reviews

    @connection.transaction(requires_new: true) { @migration.migrate(:up) }

    migrated = reviews
    original_fields = migrated.map { |row| row.except('decision_key', 'decision_fingerprint', 'reviewed_blob_id') }
    assert_equal original, original_fields
    assert_equal %w[legacy-proof-review:1 legacy-proof-review:2], migrated.pluck('decision_key')
    assert_equal %w[legacy legacy], migrated.pluck('decision_fingerprint')
    assert_equal [nil, nil], migrated.pluck('reviewed_blob_id')

    columns = @connection.columns(:proof_reviews).index_by(&:name)
    %w[decision_key decision_fingerprint].each do |name|
      assert_not columns.fetch(name).null
      assert_nil columns.fetch(name).default
    end
    assert @connection.index_exists?(:proof_reviews, %i[application_id decision_key], unique: true)

    @migration.migrate(:down)

    assert_equal original, reviews
  end

  private

  def reviews
    @connection.select_all('SELECT * FROM proof_reviews ORDER BY id').to_a
  end
end
