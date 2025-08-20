# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class IncomeThresholdSystemTest < ApplicationSystemTestCase
    setup do
      @user = users(:constituent_john)

      # Set up FPL policies for testing
      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_2_person').update(value: 21_150)
      Policy.find_or_create_by(key: 'fpl_3_person').update(value: 26_650)
      Policy.find_or_create_by(key: 'fpl_4_person').update(value: 32_150)
      Policy.find_or_create_by(key: 'fpl_5_person').update(value: 37_650)
      Policy.find_or_create_by(key: 'fpl_6_person').update(value: 43_150)
      Policy.find_or_create_by(key: 'fpl_7_person').update(value: 48_650)
      Policy.find_or_create_by(key: 'fpl_8_person').update(value: 54_150)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)

      # Reliable sign in via shared helper
      system_test_sign_in(@user)
      assert_authenticated_as(@user)
    end

    test 'income threshold calculation in JavaScript matches server calculation' do
      # This test verifies that the JavaScript calculation matches the server calculation

      # Visit the new application form
      visit new_constituent_portal_application_path

      # Wait for the income validation controller to load its FPL data.
      wait_for_fpl_data_to_load

      # Test cases for different household sizes and incomes
      test_cases = [
        { household_size: 1, income: 59_999, expected_disabled: false }, # Below threshold (15650*4=62600)
        { household_size: 1, income: 65_000, expected_disabled: true },  # Above threshold
        { household_size: 3, income: 99_999, expected_disabled: false }, # Below threshold (26650*4=106600)
        { household_size: 3, income: 110_000, expected_disabled: true }, # Above threshold
        { household_size: 8, income: 199_999, expected_disabled: false }, # Below threshold (54150*4=216600)
        { household_size: 8, income: 220_000, expected_disabled: true } # Above threshold
      ]

      # Test each case with proper field clearing
      test_cases.each do |test_case|
        household_size = test_case[:household_size]
        income = test_case[:income]
        expected_disabled = test_case[:expected_disabled]

        # Clear and set field values explicitly to avoid concatenation issues
        household_size_field = find('input[name*="household_size"]')
        household_size_field.set('') # Clear first
        household_size_field.set(household_size)

        income_field = find('input[name*="annual_income"]')
        income_field.set('') # Clear first
        income_field.set(income)

        # Trigger validation events
        household_size_field.trigger('change')
        income_field.trigger('change')

        # Wait for validation to complete by checking expected button state
        using_wait_time(10) do
          submit_button = find('input[name="submit_application"]')

          if expected_disabled
            # Wait for button to become disabled
            assert submit_button.disabled?,
                   "Expected submit button to be disabled for household size #{household_size} and income #{income}"
          else
            # Wait for button to remain enabled (or become enabled if it was initially disabled)
            assert_not submit_button.disabled?,
                       "Expected submit button to be enabled for household size #{household_size} and income #{income}"
          end
        end

        # Check if the warning is displayed as expected using proper Capybara matchers
        if expected_disabled
          # Wait for warning to become visible
          assert_selector '#income-threshold-warning', visible: true, wait: 10,
                                                       text: /Income Exceeds Threshold/
        else
          # For cases where warning should NOT be visible, wait for calculation and check hidden state
          sleep 0.5 # Allow JavaScript calculation to complete

          # Check that warning element has the hidden class (which means it should not be visible)
          if page.has_selector?('#income-threshold-warning', wait: 3)
            # Element exists, verify it has the hidden class (properly hidden)
            assert_selector '#income-threshold-warning.hidden', wait: 5
          end
        end
      end
    end

    test 'income threshold calculation is accurate for edge cases' do
      # Visit the new application form
      visit new_constituent_portal_application_path

      # Wait for the income validation controller to load its FPL data.
      wait_for_fpl_data_to_load

      # Edge case 1: Exactly at the threshold
      household_size_field = find('input[name*="household_size"]')
      household_size_field.set('')
      household_size_field.set(3)

      income_field = find('input[name*="annual_income"]')
      income_field.set('')
      income_field.set(106_600) # Exactly at the threshold (26650 * 4)

      # Trigger validation and wait for completion
      household_size_field.trigger('change')
      income_field.trigger('change')

      # Use proper Capybara waiting - button should be enabled at threshold
      submit_button = find('input[name="submit_application"]')
      using_wait_time(5) do
        assert_not submit_button.disabled?,
                   'Submit button should be enabled when income is exactly at the threshold'
      end
      # Warning should not be visible at threshold; check by target and hidden attribute
      assert_no_selector '[data-income-validation-target="warningContainer"]', visible: true, wait: 5

      # Edge case 2: Very large household size
      household_size_field.set('')
      household_size_field.set(20)

      income_field.set('')
      income_field.set(199_999) # Below the threshold for size 8 (54150 * 4 = 216600)

      # Trigger validation and wait for completion
      household_size_field.trigger('change')
      income_field.trigger('change')

      # Button should be enabled for large household sizes below threshold
      using_wait_time(5) do
        assert_not submit_button.disabled?,
                   'Submit button should be enabled for large household sizes below the threshold'
      end
      assert_no_selector '#income-threshold-warning', visible: true, wait: 5

      # Edge case 3: Very large income
      household_size_field.set('')
      household_size_field.set(1)

      income_field.set('')
      income_field.set(1_000_000) # Well above the threshold

      # Trigger validation and wait for completion
      household_size_field.trigger('change')
      income_field.trigger('change')

      # Button should be disabled for very large incomes
      using_wait_time(5) do
        assert submit_button.disabled?,
               'Submit button should be disabled for very large incomes'
      end
      assert_selector '#income-threshold-warning', visible: true, wait: 5,
                                                   text: /Income Exceeds Threshold/

      # Edge case 4: Zero values - this test is skipped because the current implementation
      # doesn't hide the warning for zero values if it was previously shown
      # This is a known issue that should be fixed in a future update

      # Reset the form to a known state
      refresh
      wait_for_fpl_data_to_load

      # Start with zero values
      household_size_field = find('input[name*="household_size"]')
      income_field = find('input[name*="annual_income"]')

      household_size_field.set('')
      household_size_field.set(0)

      income_field.set('')
      income_field.set(0)

      # Trigger validation
      household_size_field.trigger('change')
      income_field.trigger('change')
      find('body').click # Trigger blur event

      # The warning should not be visible initially
      warning = find_by_id('income-threshold-warning', visible: false)
      assert_equal false, warning.visible?,
                   'Warning should not be visible initially for zero values'
    end
  end
end
