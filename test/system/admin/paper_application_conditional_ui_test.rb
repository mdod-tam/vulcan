# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  # The paper application form reveals each step as staff make the choice before it:
  # applicant type, then an existing or new adult (or a guardian), then the shared sections.
  class PaperApplicationConditionalUiTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin, email: "paper_app_ui_admin_#{Time.now.to_i}_#{rand(10_000)}@example.com")
      system_test_sign_in(@admin)
      visit new_admin_paper_application_path
      wait_for_stimulus_controller('applicant-type')
    end

    test 'the form opens on applicant type and adult search, with later steps hidden' do
      assert_selector 'h2#step1-heading', text: 'Who is this application for?'
      within('fieldset[data-applicant-type-target="radioSection"]') do
        assert_selector 'legend', text: 'Applicant type'
        assert_checked_field 'An Adult (applying for themselves)'
        assert_unchecked_field 'A Dependent (minor or adult requiring guardian)'
      end

      assert_selector 'h2#step2-adult-search-heading', text: 'Search for Existing Applicant'
      assert_button 'Create New Applicant'

      assert_no_selector '#self-info-section'
      assert_no_selector '#guardian-info-section'
      assert_no_selector '[data-applicant-type-target="sectionsForDependentWithGuardian"]'
      assert_no_selector '#proof-heading'
    end

    test 'creating a new adult shows the applicant fields and the shared sections' do
      click_button 'Create New Applicant'

      within('#self-info-section') do
        assert_selector 'input#constituent_first_name'
        assert_selector 'input#constituent_email'
        assert_selector 'input#constituent_physical_address_1'
      end
      assert_selector 'fieldset legend', text: 'Disability Information (for the Applicant)'
      assert_selector 'fieldset legend', text: 'Certifying Professional Information'
      assert_selector '#proof-heading', text: 'Proof Documents'

      assert_no_selector '#guardian-info-section'
      assert_no_selector '[data-applicant-type-target="sectionsForDependentWithGuardian"]'
    end

    test 'choosing a dependent and a guardian without an address shows the dependent fields' do
      guardian = create(:constituent, first_name: 'Guardian', last_name: 'Test',
                                      email: "guardian.test.#{Time.now.to_i}@example.com", phone: '555-123-4567',
                                      physical_address_1: nil, city: nil, state: nil, zip_code: nil)

      choose 'A Dependent (minor or adult requiring guardian)'
      assert_selector '#guardian-info-section'
      assert_no_selector '#adult-search-section'

      fill_in 'guardian_search_q', with: guardian.full_name
      within('#guardian_search_results') { find('li', text: /#{guardian.full_name}/i, wait: 15).click }

      within('[data-guardian-picker-target="selectedPane"]') do
        assert_text guardian.full_name
        assert_text guardian.email
        assert_text 'No address information available'
        assert_text 'Currently has 0 dependents'
        assert_button 'Change Selection'
      end
      assert_no_selector '[data-guardian-picker-target="searchPane"]'

      within('[data-applicant-type-target="sectionsForDependentWithGuardian"]') do
        assert_selector 'input#dependent_constituent_first_name'
      end
      assert_selector '[data-dependent-fields-target="relationshipType"][required]'
      # A new dependent defaults to the guardian's address, so separate address fields start hidden.
      assert_no_selector '[data-dependent-fields-target="addressFields"]'
      assert_selector '#proof-heading', text: 'Proof Documents'
    end
  end
end
