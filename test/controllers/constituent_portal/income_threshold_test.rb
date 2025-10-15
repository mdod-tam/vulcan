# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  # Tests for FPL threshold calculation and server-rendered data
  # Note: AJAX endpoint was removed in favor of server-rendered data approach
  class IncomeThresholdTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      # Use factory bot instead of fixture
      @user = create(:constituent)
      sign_in_for_integration_test(@user)

      # Set up FPL policies for testing
      setup_fpl_policies
    end

    test 'helper methods provide correct FPL data for server rendering' do
      # Access a page to get controller context
      get new_constituent_portal_application_path
      assert_response :success

      # Get data from helper methods (used for server-rendered data attributes)
      thresholds_json = @controller.fpl_thresholds_json
      modifier = @controller.fpl_modifier_value

      # Parse and verify thresholds
      thresholds = JSON.parse(thresholds_json)
      assert_equal 15_650, thresholds['1']
      assert_equal 21_150, thresholds['2']
      assert_equal 26_650, thresholds['3']
      assert_equal 32_150, thresholds['4']
      assert_equal 37_650, thresholds['5']
      assert_equal 43_150, thresholds['6']
      assert_equal 48_650, thresholds['7']
      assert_equal 54_150, thresholds['8']
      assert_equal 400, modifier
    end

    test 'income threshold calculation via service is correct' do
      # This test verifies that the IncomeThresholdCalculationService
      # calculates thresholds correctly for different household sizes

      # Test cases for different household sizes and incomes
      test_cases = [
        { household_size: 1, income: 59_999, expected_result: true },  # Below threshold
        { household_size: 1, income: 62_601, expected_result: false }, # Above threshold (62,600 threshold)
        { household_size: 3, income: 99_999, expected_result: true },  # Below threshold
        { household_size: 3, income: 106_601, expected_result: false }, # Above threshold
        { household_size: 8, income: 216_599, expected_result: true },  # Below threshold
        { household_size: 8, income: 216_601, expected_result: false }, # Above threshold
        { household_size: 10, income: 216_599, expected_result: true },  # Above household size 8, use size 8 threshold
        { household_size: 10, income: 216_601, expected_result: false }  # Above household size 8, use size 8 threshold
      ]

      # Verify each test case using the service directly
      test_cases.each do |test_case|
        household_size = test_case[:household_size]
        income = test_case[:income]
        expected_result = test_case[:expected_result]

        # Use the service to calculate threshold
        result = IncomeThresholdCalculationService.call(household_size)
        assert result.success?, "Service should successfully calculate threshold for household size #{household_size}"

        threshold = result.data[:threshold]

        # Check if income is below threshold
        actual_result = income <= threshold

        assert_equal expected_result, actual_result,
                     "Expected income #{income} to be #{expected_result ? 'below' : 'above'} threshold #{threshold} for household size #{household_size}"
      end
    end
  end
end
