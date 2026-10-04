# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class IncomeThresholdSystemTest < ApplicationSystemTestCase
    setup do
      @user = users(:constituent_john)

      # The threshold is 400% of FPL, for example 15_650 * 4 = 62_600 for one person.
      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_2_person').update(value: 21_150)
      Policy.find_or_create_by(key: 'fpl_3_person').update(value: 26_650)
      Policy.find_or_create_by(key: 'fpl_4_person').update(value: 32_150)
      Policy.find_or_create_by(key: 'fpl_5_person').update(value: 37_650)
      Policy.find_or_create_by(key: 'fpl_6_person').update(value: 43_150)
      Policy.find_or_create_by(key: 'fpl_7_person').update(value: 48_650)
      Policy.find_or_create_by(key: 'fpl_8_person').update(value: 54_150)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)

      system_test_sign_in(@user)
      assert_authenticated_as(@user)
    end

    test 'income threshold calculation in JavaScript matches server calculation' do
      visit new_constituent_portal_application_path

      wait_for_fpl_data_to_load

      test_cases = [
        { household_size: 1, income: 59_999, expected_warning: false }, # Below threshold (15650*4=62600)
        { household_size: 1, income: 65_000, expected_warning: true },  # Above threshold
        { household_size: 3, income: 99_999, expected_warning: false }, # Below threshold (26650*4=106600)
        { household_size: 3, income: 110_000, expected_warning: true }, # Above threshold
        { household_size: 8, income: 199_999, expected_warning: false }, # Below threshold (54150*4=216600)
        { household_size: 8, income: 220_000, expected_warning: true } # Above threshold
      ]

      test_cases.each do |test_case|
        household_size = test_case[:household_size]
        income = test_case[:income]
        expected_warning = test_case[:expected_warning]

        # set('') before each value prevents concatenation.
        household_size_field = find('input[name*="household_size"]')
        household_size_field.set('')
        household_size_field.set(household_size)

        income_field = find('input[name*="annual_income"]')
        income_field.set('')
        income_field.set(income)

        household_size_field.trigger('change')
        income_field.trigger('change')

        # Submit stays disabled until every visible required control is valid.
        assert_selector 'input[name="submit_application"]:disabled', wait: 10

        if expected_warning
          assert_selector '#income-threshold-warning', visible: true, wait: 10,
                                                       text: /Income Exceeds Threshold/
        elsif page.has_selector?('#income-threshold-warning', wait: 3)
          assert_selector '#income-threshold-warning.hidden', wait: 5
        end
      end
    end

    test 'income threshold calculation is accurate for edge cases' do
      visit new_constituent_portal_application_path
      wait_for_fpl_data_to_load

      # Edge case 1: income equal to the threshold
      household_size_field = find('input[name*="household_size"]')
      household_size_field.set('')
      household_size_field.set(3)

      income_field = find('input[name*="annual_income"]')
      income_field.set('')
      income_field.set(106_600) # 26_650 * 4

      household_size_field.trigger('change')
      income_field.trigger('change')

      # Other required controls still disable submit.
      assert_selector 'input[name="submit_application"]:disabled', wait: 5

      # At or below the threshold, the warning stays in the DOM with the hidden attribute.
      assert_selector '[data-income-validation-target="warningContainer"][hidden]', visible: :all, wait: 5

      # Edge case 2: household size above 8. The threshold calculation caps the size at 8.
      household_size_field.set('')
      household_size_field.set(20)

      income_field.set('')
      income_field.set(199_999) # Below 54_150 * 4 = 216_600

      household_size_field.trigger('change')
      income_field.trigger('change')

      # Other required controls still disable submit.
      assert_selector 'input[name="submit_application"]:disabled', wait: 5
      if page.has_selector?('#income-threshold-warning', wait: 2)
        # has_selector? finds only visible elements, so this branch does not run for a hidden warning.
        assert_selector '#income-threshold-warning.hidden', wait: 5
      end

      # Edge case 3: very large income
      household_size_field.set('')
      household_size_field.set(1)

      income_field.set('')
      income_field.set(1_000_000)

      household_size_field.trigger('change')
      income_field.trigger('change')

      # The :disabled CSS selector lets Capybara wait.
      assert_selector 'input[name="submit_application"]:disabled', wait: 5
      assert_selector '#income-threshold-warning', visible: true, wait: 5,
                                                   text: /Income Exceeds Threshold/

      # Edge case 4: zero values, from a clean form
      refresh
      wait_for_fpl_data_to_load

      household_size_field = find('input[name*="household_size"]')
      income_field = find('input[name*="annual_income"]')

      household_size_field.set('')
      household_size_field.set(0)

      income_field.set('')
      income_field.set(0)

      household_size_field.trigger('change')
      income_field.trigger('change')
      find('body').click # blur

      # The warning can stay in the DOM. It must have the hidden class or attribute, or not be visible.
      warning_element = find_by_id('income-threshold-warning', visible: :all)
      warning_hidden = warning_element[:class]&.include?('hidden') ||
                       warning_element[:hidden].present? ||
                       !warning_element.visible?
      assert warning_hidden, 'Warning should be hidden for zero values'
    end
  end
end
