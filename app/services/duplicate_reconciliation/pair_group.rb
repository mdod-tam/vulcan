# frozen_string_literal: true

module DuplicateReconciliation
  # Read-only queue projection that presents connected unresolved pairs as one group without
  # weakening pair-scoped authority. Every action still carries exactly one canonical pair.
  class PairGroup
    attr_reader :members, :pairs

    def self.build_all(pairs)
      remaining = pairs.sort_by(&:ids)
      groups = []

      until remaining.empty?
        connected_pairs = [remaining.shift]

        loop do
          member_ids = connected_pairs.flat_map(&:ids).uniq
          adjacent_pairs = remaining.select { |pair| pair.ids.intersect?(member_ids) }
          break if adjacent_pairs.empty?

          connected_pairs.concat(adjacent_pairs)
          remaining -= adjacent_pairs
        end

        groups << new(connected_pairs)
      end

      groups.sort_by(&:ids)
    end

    def initialize(pairs)
      @pairs = pairs.sort_by(&:ids).freeze
      @members = indexed_members.values.sort_by(&:id).freeze
    end

    def ids
      members.map(&:id)
    end

    def display_name
      members.first.name
    end

    private

    def indexed_members
      pairs.each_with_object({}) do |pair, indexed|
        [pair.first, pair.second].each { |member| indexed[member.id] ||= member }
      end
    end
  end
end
