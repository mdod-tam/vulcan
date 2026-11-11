# frozen_string_literal: true

module DuplicateReconciliation
  # Presents one page of name/DOB matches. Each action still carries one exact pair.
  class PairGroup
    attr_reader :members, :pairs

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
