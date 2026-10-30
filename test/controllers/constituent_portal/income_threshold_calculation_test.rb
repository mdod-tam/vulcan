# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  # FPL threshold calculation and the thresholds rendered into the page.
  class IncomeThresholdCalculationTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @user = create(:constituent)
      sign_in_for_integration_test(@user)

      setup_fpl_policies
    end

    test 'helper methods provide correct FPL data for server rendering' do
      get new_constituent_portal_application_path
      assert_response :success

      client_data = IncomeThresholdCalculationService.client_data
      modifier = client_data[:modifier]

      thresholds = client_data[:thresholds]
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

      test_cases.each do |test_case|
        household_size = test_case[:household_size]
        income = test_case[:income]
        expected_result = test_case[:expected_result]

        result = IncomeThresholdCalculationService.call(household_size)
        assert result.success?, "Service should successfully calculate threshold for household size #{household_size}"

        threshold = result.data[:threshold]

        actual_result = income <= threshold

        assert_equal expected_result, actual_result,
                     "Expected income #{income} to be #{expected_result ? 'below' : 'above'} threshold #{threshold} for household size #{household_size}"
      end
    end
  end
end
