# frozen_string_literal: true

# Service for calculating income thresholds based on Federal Poverty Level (FPL) guidelines
class IncomeThresholdCalculationService < BaseService
  TABLE_HOUSEHOLD_SIZE = 8

  def self.call(household_size)
    new(household_size).call
  end

  # The data client-side income validation needs: base FPL by household size and the modifier percentage.
  # Forms decide whether income is collected, including persisted application requirements.
  def self.client_data
    unavailable = { thresholds: {}, modifier: 0, additional_person: nil }
    results = (1..TABLE_HOUSEHOLD_SIZE).map { |size| call(size) }.select(&:success?)
    return unavailable if results.empty?

    larger_household = call(TABLE_HOUSEHOLD_SIZE + 1)

    { thresholds: results.to_h { |result| [result.data[:household_size].to_s, result.data[:base_fpl]] },
      modifier: results.first.data[:modifier], additional_person: larger_household.success? ? larger_household.data[:additional_person] : nil }
  end

  def initialize(household_size)
    super()
    @household_size = household_size
  end

  def call
    size = Integer(@household_size.to_s, 10)
    raise ArgumentError, 'Household size must be a positive whole number' unless size.positive?

    base_fpl = positive_policy!("fpl_#{[size, TABLE_HOUSEHOLD_SIZE].min}_person")
    additional_person = size > TABLE_HOUSEHOLD_SIZE ? positive_policy!('fpl_additional_person') : 0
    base_fpl += [size - TABLE_HOUSEHOLD_SIZE, 0].max * additional_person
    modifier = positive_policy!('fpl_modifier_percentage')
    threshold = (base_fpl.to_d * modifier / 100).round(2)

    success('Threshold calculated successfully', {
              household_size: size,
              base_fpl: base_fpl,
              additional_person: additional_person,
              modifier: modifier,
              threshold: threshold
            })
  rescue StandardError => e
    log_error(e, "Failed to calculate income threshold for household size #{@household_size}")
    failure('Income thresholds could not be checked. Please try again later.')
  end

  private

  def positive_policy!(key)
    value = Policy.get(key)
    raise ArgumentError, "Missing or invalid income policy: #{key}" unless value&.positive?

    value
  end
end
