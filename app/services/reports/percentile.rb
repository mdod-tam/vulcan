# frozen_string_literal: true

module Reports
  module Percentile
    def self.calculate(sorted_values, fraction)
      rank = (sorted_values.size - 1) * fraction
      lower = sorted_values.fetch(rank.floor)
      upper = sorted_values.fetch(rank.ceil)
      (lower + ((upper - lower) * (rank % 1))).round(1)
    end
  end
end
