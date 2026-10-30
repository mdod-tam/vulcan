# frozen_string_literal: true

# Service for calculating income thresholds based on Federal Poverty Level (FPL) guidelines
class IncomeThresholdCalculationService < BaseService
  MAX_HOUSEHOLD_SIZE = 8
  # The modifier client validation assumes when the policy cannot be read.
  FALLBACK_MODIFIER = 400

  def self.call(household_size)
    new(household_size).call
  end

  # The data client-side income validation needs: base FPL by household size and the modifier percentage.
  # Both are empty when income proof is not collected.
  # @return [Hash] thresholds (household size => base FPL) and modifier
  def self.client_data
    return { thresholds: {}, modifier: 0 } unless FeatureFlag.income_proof_required?

    thresholds = (1..MAX_HOUSEHOLD_SIZE).to_h do |size|
      result = call(size)
      [size.to_s, result.success? ? result.data[:base_fpl] : 0]
    end
    modifier = call(1)

    { thresholds: thresholds, modifier: modifier.success? ? modifier.data[:modifier] : FALLBACK_MODIFIER }
  end

  def initialize(household_size)
    super()
    @household_size = household_size.to_i
  end

  def call
    base_fpl = Policy.get("fpl_#{[@household_size, MAX_HOUSEHOLD_SIZE].min}_person").to_i
    modifier = Policy.get('fpl_modifier_percentage').to_i
    threshold = base_fpl * (modifier / 100.0)

    success('Threshold calculated successfully', {
              household_size: @household_size,
              base_fpl: base_fpl,
              modifier: modifier,
              threshold: threshold
            })
  rescue StandardError => e
    log_error(e, "Failed to calculate income threshold for household size #{@household_size}")
    failure("Unable to calculate income threshold: #{e.message}")
  end
end
