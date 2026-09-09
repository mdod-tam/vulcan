# frozen_string_literal: true

require 'test_helper'

module DuplicateReconciliation
  class PairGroupTest < ActiveSupport::TestCase
    test 'builds stable groups from connected pairs and does not invent filtered pairings' do
      first_group = create_match_group('First', count: 3, date_of_birth: Date.new(1982, 3, 4))
      second_group = create_match_group('Second', count: 2, date_of_birth: Date.new(1983, 4, 5))
      member_ids = (first_group + second_group).map(&:id)
      population_pairs = Population.new.pairs.select { |pair| (pair.ids - member_ids).empty? }
      omitted_pair_ids = first_group.first(2).map(&:id).sort
      visible_pairs = population_pairs.reject { |pair| pair.ids == omitted_pair_ids }.reverse

      groups = PairGroup.build_all(visible_pairs)

      assert_equal [first_group.map(&:id).sort, second_group.map(&:id).sort], groups.map(&:ids)
      assert_equal first_group.map(&:id).sort.combination(2).to_a - [omitted_pair_ids], groups.first.pairs.map(&:ids)
      assert_equal groups.first.members.map(&:id).uniq, groups.first.members.map(&:id)
      assert_not_includes groups.first.pairs.map(&:ids), omitted_pair_ids
    end

    private

    def create_match_group(prefix, count:, date_of_birth:)
      token = SecureRandom.hex(4)
      Array.new(count) do |index|
        create(
          :constituent,
          first_name: prefix,
          last_name: "PairGroup#{token}",
          date_of_birth: date_of_birth,
          email: "pair-group-#{token}-#{index}@example.com",
          needs_duplicate_review: false
        )
      end
    end
  end
end
