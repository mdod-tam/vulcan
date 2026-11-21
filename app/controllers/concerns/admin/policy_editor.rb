# frozen_string_literal: true

module Admin
  module PolicyEditor
    extend ActiveSupport::Concern

    private

    def load_policies
      @icanconnect_setting = ::Icanconnect::Setting.find_or_initialize_by(id: ::Icanconnect::Setting::ID)
      @policies = Policy.order(:key).load
      @policies_by_key = @policies.index_by(&:key)
      @additional_person_policy = @policies_by_key['fpl_additional_person']
      @modifier_policy = @policies_by_key['fpl_modifier_percentage']
      @period_policy = @policies_by_key['proof_submission_rate_period']
      @web_policy = @policies_by_key['proof_submission_rate_limit_web']
      @fpl_policy_rows = (1..IncomeThresholdCalculationService::TABLE_HOUSEHOLD_SIZE).map do |size|
        key = "fpl_#{size}_person"
        [size, key, @policies_by_key[key]]
      end
      @voucher_disability_rows = %w[hearing vision speech mobility cognition].map do |type|
        key = "voucher_value_#{type}_disability"
        [type, key, @policies_by_key[key]]
      end
      @voucher_setting_rows = %w[voucher_validity_period_months voucher_minimum_redemption_amount].map { |key| [key, @policies_by_key[key]] }
      defaults = Baseline::Policies::DEFAULTS.slice(*@fpl_policy_rows.map(&:second), *@voucher_setting_rows.map(&:first), 'fpl_additional_person')
      defaults.merge!('fpl_modifier_percentage' => 400, 'proof_submission_rate_period' => 1, 'proof_submission_rate_limit_web' => 5)
      defaults.merge!(@voucher_disability_rows.to_h { |_, key, _| [key, 500] })
      @missing_policy_defaults = defaults.reject { |key, _| @policies_by_key.key?(key) }
      @recent_changes = PolicyChange.includes(:policy, :user).order(created_at: :desc).limit(10)
      @mileage_rates = MileageRate.order(effective_on: :desc).to_a
      @new_mileage_rate = MileageRate.new
      @mileage_rate_events = Event.where(auditable_type: 'MileageRate').includes(:user).order(created_at: :desc, id: :desc).limit(10)
    end
  end
end
