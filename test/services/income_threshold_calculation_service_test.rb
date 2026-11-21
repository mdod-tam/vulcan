# frozen_string_literal: true

require 'test_helper'

class IncomeThresholdCalculationServiceTest < ActiveSupport::TestCase
  setup do
    Policy.stubs(:get).returns(nil)
    Baseline::Policies::DEFAULTS.select { |key, _value| key.start_with?('fpl_') }.each do |key, value|
      Policy.stubs(:get).with(key).returns(value)
    end
  end

  test 'households above eight use the configured additional-person amount' do
    { 8 => 216_600, 9 => 238_600, 10 => 260_600 }.each do |size, threshold|
      result = IncomeThresholdCalculationService.call(size)
      assert result.success?, result.message
      assert_equal threshold, result.data.fetch(:threshold)
    end
    Policy.stubs(:get).with('fpl_additional_person').returns(6_000)
    assert_equal 264_600, IncomeThresholdCalculationService.call(10).data.fetch(:threshold)
    assert_equal 6_000, IncomeThresholdCalculationService.client_data.fetch(:additional_person)
  end

  test 'invalid households and missing or invalid policies do not become zero thresholds' do
    [0, -1, '2.5', 'unknown', nil].each do |size|
      assert_not IncomeThresholdCalculationService.call(size).success?
    end
    Policy.stubs(:get).with('fpl_additional_person').returns(nil)
    assert_not IncomeThresholdCalculationService.call(9).success?
    data = IncomeThresholdCalculationService.client_data
    assert_equal (1..8).map(&:to_s), data.fetch(:thresholds).keys
    assert_equal 400, data.fetch(:modifier)
    assert_nil data.fetch(:additional_person)
    Policy.stubs(:get).with('fpl_modifier_percentage').returns(0)
    assert_not IncomeThresholdCalculationService.call(1).success?
    assert_empty IncomeThresholdCalculationService.client_data.fetch(:thresholds)
  end

  test 'a missing household table row leaves configured sizes available to the client' do
    Policy.stubs(:get).with('fpl_3_person').returns(nil)

    data = IncomeThresholdCalculationService.client_data

    assert_equal %w[1 2 4 5 6 7 8], data.fetch(:thresholds).keys
    assert_equal 54_150, data.fetch(:thresholds).fetch('8')
    assert_equal 400, data.fetch(:modifier)
    assert_equal 5_500, data.fetch(:additional_person)
    assert_not IncomeThresholdCalculationService.call(3).success?
    assert IncomeThresholdCalculationService.call(9).success?
  end

  test 'configured client data remains available for persisted income requirements when MAT income collection changes' do
    FeatureFlag.stubs(:income_proof_required?).returns(false)
    data = IncomeThresholdCalculationService.client_data
    assert_equal 54_150, data.fetch(:thresholds).fetch('8')
    assert_equal 400, data.fetch(:modifier)
    assert_equal 5_500, data.fetch(:additional_person)
  end
end
