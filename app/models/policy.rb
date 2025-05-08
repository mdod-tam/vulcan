# frozen_string_literal: true

class Policy < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :value, presence: true, numericality: { only_integer: true }
  validates :value, numericality: {
    greater_than: 0,
    less_than_or_equal_to: 100
  }, if: -> { RATE_LIMIT_KEYS.include?(key) }

  has_many :policy_changes
  attr_accessor :updated_by

  after_update :log_change

  RATE_LIMIT_KEYS = %w[
    proof_submission_rate_limit_web
    proof_submission_rate_limit_email
    proof_submission_rate_period
  ].freeze

  VOUCHER_KEYS = %w[
    voucher_value_hearing_disability
    voucher_value_vision_disability
    voucher_value_speech_disability
    voucher_value_mobility_disability
    voucher_value_cognition_disability
    voucher_validity_period_months
    voucher_minimum_redemption_amount
  ].freeze

  def self.rate_limit_for(action, method)
    max_value = get("#{action}_rate_limit_#{method}")
    period_value = get("#{action}_rate_period")

    # Return nil if we don't have any rate limit configuration
    # This allows callers to handle the case appropriately
    return nil if max_value.nil? && period_value.nil?

    # Use reasonable defaults if either value is missing
    max_value ||= 10 # Default to 10 submissions
    period_value ||= 24 # Default to 24 hours

    {
      max: max_value,
      period: period_value.hours
    }
  end

  def self.get(key)
    find_by(key: key)&.value
  end

  def self.set(key, value)
    policy = find_or_initialize_by(key: key)
    policy.value = value
    policy.save!
  end

  def self.voucher_validity_period
    months = get('voucher_validity_period_months') || 6
    months.months
  end

  def self.voucher_minimum_redemption_amount
    get('voucher_minimum_redemption_amount') || 10
  end

  def self.voucher_value_for_disability(disability_type)
    value = get("voucher_value_#{disability_type}_disability")
    value ? value.to_i : 0
  end

  private

  def log_change
    return unless saved_change_to_value?

    policy_changes.create!(
      user: updated_by, # Changed from Current.user to updated_by
      previous_value: value_before_last_save,
      new_value: value
    )
  end

  validate :validate_voucher_value

  def validate_voucher_value
    return unless VOUCHER_KEYS.include?(key)

    if key.end_with?('_months', '_amount')
      errors.add(:value, 'must be between 1 and 12') if key.end_with?('_months') && !value.between?(1, 12)
      errors.add(:value, 'must be between 1 and 1000') if key.end_with?('_amount') && !value.between?(1, 1000)
    else
      errors.add(:value, 'must be between 1 and 10000') unless value.between?(1, 10_000)
    end
  end
end
