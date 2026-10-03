# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class PaperApplicationConditionalUiTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin, email: "paper_app_ui_admin_#{Time.now.to_i}_#{rand(10_000)}@example.com")
      system_test_sign_in(@admin)
      visit admin_applications_path
      assert_selector 'h1', text: 'Dashboard' # Test compatibility heading.

      visit new_admin_paper_application_path
      wait_for_turbo
    end

    test 'UI initial state before guardian selection' do

      assert_selector 'fieldset legend', text: 'Who is this application for?', visible: true
      assert_selector 'fieldset[data-applicant-type-target="radioSection"]', visible: true

      assert_selector 'fieldset legend', text: "Applicant's Information", visible: true
      assert_selector 'fieldset[data-applicant-type-target="adultSection"]', visible: true

      assert_selector 'fieldset legend', text: 'Guardian Information', visible: :all
      assert_selector '[data-applicant-type-target="guardianSection"]', visible: :all
      guardian_section = find('[data-applicant-type-target="guardianSection"]', visible: :all)
      assert guardian_section[:class].include?('hidden'), "Guardian section should have 'hidden' class"

      assert_selector '[data-guardian-picker-target="selectedPane"]', visible: :all
      selected_pane = find('[data-guardian-picker-target="selectedPane"]', visible: :all)
      assert selected_pane[:class].include?('hidden'), "Selected pane should have 'hidden' class"

      assert_selector '[data-applicant-type-target="sectionsForDependentWithGuardian"]', visible: :all
      dependent_section = find('[data-applicant-type-target="sectionsForDependentWithGuardian"]', visible: :all)
      assert dependent_section[:class].include?('hidden'), "Dependent section should have 'hidden' class"

    end

    test 'UI state after guardian selection (guardian with no address)' do
      guardian = create(:constituent,
                        first_name: 'Guardian',
                        last_name: 'Test',
                        email: "guardian.test.#{Time.now.to_i}@example.com",
                        phone: '555-123-4567',
                        physical_address_1: nil,
                        city: nil,
                        state: nil,
                        zip_code: nil)

      choose 'A Dependent (must select existing guardian in system or enter guardian\'s information)'

      wait_for_turbo
      wait_for_stimulus_controller('applicant-type')
      wait_for_stimulus_controller('guardian-picker')
      wait_for_stimulus_controller('admin-user-search')

      assert_selector '[data-applicant-type-target="guardianSection"]', visible: true, wait: 5

      within_fieldset_tagged('Guardian Information') do
        fill_in 'guardian_search_q', with: guardian.full_name
      end

      assert_selector '#guardian_search_results li', text: /#{guardian.full_name}/i, wait: 5

      within('#guardian_search_results') do
        find('li', text: /#{guardian.full_name}/i, wait: 15).click
      end

      wait_for_selector '[data-guardian-picker-target="selectedPane"]', visible: true, timeout: 10

      wait_for_selector '[data-applicant-type-target="sectionsForDependentWithGuardian"]', visible: true, timeout: 5

      selected_display_selector = '[data-guardian-picker-target="selectedPane"]'
      assert_selector selected_display_selector, visible: true, wait: 15
      within(selected_display_selector) do
        assert_text guardian.full_name
        assert_text guardian.email
        assert_text 'No address information available'
        assert_text 'Currently has 0 dependents'
        assert_selector 'button', text: 'Change Selection', visible: true
      end

      assert_selector '[data-guardian-picker-target="searchPane"]', visible: :all
      search_pane = find('[data-guardian-picker-target="searchPane"]', visible: :all)
      assert search_pane[:class].include?('hidden'), "Search pane should have 'hidden' class"

      # The controller hides the applicant-type radios after guardian selection.
      assert_selector 'fieldset[data-applicant-type-target="radioSection"]', visible: :all

      assert_selector '[data-applicant-type-target="sectionsForDependentWithGuardian"]', visible: true
      within('[data-applicant-type-target="sectionsForDependentWithGuardian"]') do
        assert_selector 'fieldset legend', text: 'New Dependent Information'
        assert_selector 'input#dependent_constituent_first_name', visible: true
      end

      assert_selector '[data-dependent-fields-target="relationshipType"]', visible: true
      assert_selector '[data-dependent-fields-target="relationshipType"][required]', visible: true

      # The selected pane reports a missing guardian address without an address editor.

      # A new dependent defaults to the guardian address, so separate address fields start hidden.
      assert_selector '[data-dependent-fields-target="addressFields"]', visible: :all
      address_fields = find('[data-dependent-fields-target="addressFields"]', visible: :all)
      assert address_fields[:class].include?('hidden'), "Dependent address fields should have 'hidden' class"
    end

    test 'UI state for adult-only flow (no guardian selected)' do

      assert_selector '[data-guardian-picker-target="searchPane"]', visible: :all
      search_pane = find('[data-guardian-picker-target="searchPane"]', visible: :all)
      guardian_section = search_pane.ancestor('[data-applicant-type-target="guardianSection"]')
      assert guardian_section[:class].include?('hidden'), "Guardian section should have 'hidden' class for adult flow"

      assert_selector '[data-guardian-picker-target="selectedPane"]', visible: :all
      selected_pane = find('[data-guardian-picker-target="selectedPane"]', visible: :all)
      assert selected_pane[:class].include?('hidden'), "Selected pane should have 'hidden' class"

      assert_selector 'fieldset[data-applicant-type-target="radioSection"]', visible: true
      within('fieldset[data-applicant-type-target="radioSection"]') do
        assert_selector 'input#applicant_is_adult', visible: true
        assert_selector 'input#applicant_is_minor', visible: true
      end

      assert_selector '[data-applicant-type-target="sectionsForDependentWithGuardian"]', visible: :all
      dependent_section = find('[data-applicant-type-target="sectionsForDependentWithGuardian"]', visible: :all)
      assert dependent_section[:class].include?('hidden'), "Dependent section should have 'hidden' class for adult flow"

      # The parent section controls the relationship field's visibility.
      assert_selector '[data-dependent-fields-target="relationshipType"]', visible: :all
      relationship_field = find('[data-dependent-fields-target="relationshipType"]', visible: :all)
      assert relationship_field.ancestor('[data-applicant-type-target="sectionsForDependentWithGuardian"]')[:class].include?('hidden'), "Relationship field's parent section should have 'hidden' class"

      assert_selector 'fieldset legend', text: 'Disability Information (for the Applicant)', visible: true
      assert_selector 'fieldset legend', text: 'Medical Provider Information', visible: true
      assert_selector 'fieldset legend', text: 'Proof Documents', visible: true

      assert_selector 'fieldset[data-applicant-type-target="adultSection"]', visible: true
      within('fieldset[data-applicant-type-target="adultSection"]') do
        assert_selector 'legend', text: "Applicant's Information"
        assert_selector 'input#constituent_first_name', visible: true
        assert_selector 'input#constituent_email', visible: true
        assert_selector 'input#constituent_physical_address_1', visible: true
      end
    end

    private

    def within_fieldset_tagged(legend_text, &)
      fieldset_element = find('fieldset', text: legend_text, match: :prefer_exact)
      within(fieldset_element, &)
    end
  end
end
