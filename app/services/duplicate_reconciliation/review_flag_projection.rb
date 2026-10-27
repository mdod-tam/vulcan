# frozen_string_literal: true

module DuplicateReconciliation
  class ReviewFlagProjection
    def initialize(population: Population.new)
      @population = population
    end

    def required_for?(user)
      DuplicateReviewCase.open.for_participant(user).exists? || @population.unresolved_for_user?(user)
    end
  end
end
