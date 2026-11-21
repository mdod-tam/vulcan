# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class IncomeThresholdSystemTest < ApplicationSystemTestCase
    setup do
      @user = create(:constituent)
      FeatureFlag.disable!(:vouchers_enabled)

      # The threshold is 400% of FPL, for example 15_650 * 4 = 62_600 for one person.
      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_2_person').update(value: 21_150)
      Policy.find_or_create_by(key: 'fpl_3_person').update(value: 26_650)
      Policy.find_or_create_by(key: 'fpl_4_person').update(value: 32_150)
      Policy.find_or_create_by(key: 'fpl_5_person').update(value: 37_650)
      Policy.find_or_create_by(key: 'fpl_6_person').update(value: 43_150)
      Policy.find_or_create_by(key: 'fpl_7_person').update(value: 48_650)
      Policy.find_or_create_by(key: 'fpl_8_person').update(value: 54_150)
      Policy.find_or_create_by(key: 'fpl_additional_person').update(value: 5_500)
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

    test 'missing additional-person policy keeps smaller households usable and permits correction' do
      Policy.find_by!(key: 'fpl_additional_person').destroy!
      visit new_constituent_portal_application_path
      wait_for_fpl_data_to_load
      fill_in 'application_household_size', with: '1'
      fill_in 'application_annual_income', with: '100'
      find_field('application_annual_income').send_keys(:tab)
      assert_selector '#application_annual_income:valid'
      fill_in 'application_household_size', with: '9'
      find_field('application_household_size').send_keys(:tab)
      assert_selector '#application_annual_income:invalid'
      assert_selector '#income-threshold-warning', text: I18n.t('applications.income_validation.unavailable'), visible: true
      assert_selector '[data-income-validation-target="incomeFieldsContainer"].bg-gray-50'
      assert_no_selector '[data-income-validation-target="incomeFieldsContainer"].bg-success-50'
      take_screenshot('income-missing-additional-policy-larger-household', html: true, full: true)
      fill_in 'application_household_size', with: '8'
      find_field('application_household_size').send_keys(:tab)
      assert_selector '#application_annual_income:valid'
      assert_selector '#income-threshold-warning[hidden]', visible: :all
      take_screenshot('income-missing-additional-policy-size-corrected', html: true, full: true)
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

      # Each person above eight adds the configured amount to base FPL.
      household_size_field.set('')
      household_size_field.set(20)

      income_field.set('')
      income_field.set(480_600) # (54_150 + 12 * 5_500) * 4

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

    test 'Spanish new and edit forms share the configured larger-household threshold and accept zero income' do
      @user.update!(locale: 'es')
      policy = Policy.find_by!(key: 'fpl_additional_person')
      policy.updated_by = create(:admin)
      policy.update!(value: 6_000)
      assert_equal 240_600, IncomeThresholdCalculationService.call(9).data.fetch(:threshold)

      visit new_constituent_portal_application_path
      wait_for_fpl_data_to_load
      assert_selector 'form[data-income-validation-additional-person-value="6000"][data-income-validation-locale-value="es"]'
      fill_in 'application_household_size', with: '9'
      fill_in 'application_annual_income', with: '240600.01'
      find_field('application_annual_income').send_keys(:tab)
      assert_selector '#income-threshold-warning', text: 'Los ingresos superan el límite', visible: true
      within('#income-threshold-warning') { assert_text '240.600' }
      assert_no_text 'Income Exceeds Threshold'
      take_screenshot('income-new-spanish-configured-nine-person-limit', full: true, html: true)

      fill_in 'application_annual_income', with: '0'
      find_field('application_annual_income').send_keys(:tab)
      assert_selector '#income-threshold-warning[hidden]', visible: :all
      assert_selector '#application_annual_income:valid'
      assert_selector '[data-autosave-target="status"]', text: I18n.t('applications.autosave.saved', locale: :es)
      draft = @user.applications.draft.sole
      assert_equal 0, draft.annual_income
      visit edit_constituent_portal_application_path(draft)
      wait_for_fpl_data_to_load
      assert_selector 'form[data-income-validation-additional-person-value="6000"][data-income-validation-locale-value="es"]'
      assert_field 'application_household_size', with: '9'
      assert_equal 0, find_field('application_annual_income').value.to_d
      assert_selector '#application_annual_income:valid'
      fill_in 'application_annual_income', with: '240600.01'
      find_field('application_annual_income').send_keys(:tab)
      assert_selector '#income-threshold-warning', text: 'Los ingresos superan el límite', visible: true
      within('#income-threshold-warning') { assert_text '240.600' }
      fill_in 'application_annual_income', with: '0'
      find_field('application_annual_income').send_keys(:tab)
      assert_selector '#income-threshold-warning[hidden]', visible: :all
      assert_selector '#application_annual_income:valid'
      take_screenshot('income-edit-spanish-zero-income', full: true, html: true)
    end

    test 'final submission checks the current server income limit and allows a visible zero-income correction' do
      ensure_system_audit_actor!
      @user.update!(hearing_disability: true)
      draft = create(:application, :draft, :with_all_proofs,
                     user: @user, income_proof_required: true, household_size: 2, annual_income: '50000.25',
                     terms_accepted: true, information_verified: true, disability_information_release_authorized: true)
      proof_ids = %i[income_proof residency_proof id_proof].index_with { |proof| draft.public_send(proof).blob.id }
      visit edit_constituent_portal_application_path(draft)
      wait_for_fpl_data_to_load
      assert_selector 'input[name="submit_application"]:enabled'
      assert_field 'application_household_size', with: '2'
      assert_field 'application_annual_income', with: '50000.25'

      # The open page still has the old cap; a policy change must also be enforced on submission.
      policy = Policy.find_by!(key: 'fpl_2_person')
      policy.updated_by = create(:admin)
      policy.update!(value: 10_000)
      assert_equal 40_000, IncomeThresholdCalculationService.call(2).data.fetch(:threshold)
      find('input[name="submit_application"]').click

      assert_selector '#error-summary', text: I18n.t('activemodel.errors.models.application_form.attributes.annual_income.income_above_limit')
      assert_field 'application_household_size', with: '2'
      assert_field 'application_annual_income', with: '50000.25'
      assert_checked_field 'terms_accepted'
      assert_checked_field 'information_verified'
      assert_selector '#income-threshold-warning', text: 'Income Exceeds Threshold', visible: true
      assert_selector 'input[name="submit_application"]:disabled'
      assert draft.reload.status_draft?
      take_screenshot('income-final-server-cap-refusal-preserves-values', full: true, html: true)

      fill_in 'application_annual_income', with: '0'
      find_field('application_annual_income').send_keys(:tab)
      assert_selector '#income-threshold-warning[hidden]', visible: :all
      assert_selector 'input[name="submit_application"]:enabled'
      take_screenshot('income-final-zero-correction-ready', full: true, html: true)
      find('input[name="submit_application"]').click

      assert_text 'Application submitted successfully!'
      assert_current_path constituent_portal_application_path(draft, format: :html)
      assert draft.reload.status_in_progress?
      assert_equal 0, draft.annual_income
      assert_equal 2, draft.household_size
      assert_equal 1, @user.applications.count
      proof_ids.each { |proof, blob_id| assert_equal blob_id, draft.public_send(proof).blob.id }
    end
  end
end
