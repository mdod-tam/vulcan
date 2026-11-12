# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  class PaperApplicationsTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper
    include SystemTestEvidence

    setup do
      @admin = create(:admin)
      sign_in(@admin, bypass_mfa_enrollment: true)

      setup_fpl_policies
    end

    test 'admin can submit application with rejected proofs' do
      visit new_admin_paper_application_path

      choose 'An Adult (applying for themselves)'
      wait_for_turbo

      fill_in_applicant_information(first_name: 'John', last_name: 'Doe')
      fill_in_application_details(household_size: 2, annual_income: 30_000)
      fill_in_disability_information
      fill_in_certifying_professional_information

      within_proof_documents_fieldset do
        choose 'reject_income_proof'

        assert_selector 'select[name="income_proof_rejection_reason"]', visible: true

        select 'Missing Income Amount', from: 'income_proof_rejection_reason'

        choose 'accept_residency_proof', allow_label_click: true
        attach_cleared_document 'residency_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
        choose 'accept_id_proof', allow_label_click: true
        attach_cleared_document 'id_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
      end
      attach_cleared_document 'disability_certification', Rails.root.join('test/fixtures/files/disability_certification_valid.pdf')
      complete_paper_application_attestations

      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: /Application #\d+ Details/, wait: 20
      end
      application = Application.order(:id).last
      assert application.income_proof_status_rejected?
      assert application.residency_proof_status_approved?
    end

    test 'guardian section remains visible when selecting a search result' do
      guardian = FactoryBot.create(:constituent, first_name: 'Alex', last_name: 'Collins')

      visit new_admin_paper_application_path

      choose 'A Dependent (minor or adult requiring guardian)'

      within 'fieldset', text: 'Guardian Information' do
        fill_in 'guardian_search_q', with: 'Alex Collins'
      end

      # Capybara waits for the asynchronous search result.
      within '#guardian_search_results' do
        find('li', text: /Alex Collins/i, wait: 5).click
      end

      within 'fieldset', text: 'Guardian Information' do
        assert_text 'Alex Collins', wait: 5
        assert_selector "input[type='hidden'][name='guardian_id'][value='#{guardian.id}']", visible: :all, wait: 5
      end

      assert_selector 'fieldset', text: 'Guardian Information', visible: true
    end

    test 'admin can create dependent application with shared contact info' do
      guardian = FactoryBot.create(:constituent,
                                   first_name: 'Alex',
                                   last_name: 'Collins',
                                   email: "alex.collins.#{Time.now.to_i}@example.com",
                                   phone: '202-981-2121',
                                   physical_address_1: '123 Main St',
                                   city: 'Baltimore',
                                   state: 'MD',
                                   zip_code: '21201')

      safe_visit new_admin_paper_application_path
      wait_for_network_idle

      choose 'A Dependent (minor or adult requiring guardian)'
      wait_for_network_idle

      assert_selector '[data-applicant-type-target="guardianSection"]', visible: true, wait: 5

      within 'fieldset', text: 'Guardian Information' do
        fill_in 'guardian_search_q', with: guardian.full_name
      end

      # Capybara waits for the asynchronous search result.
      within('#guardian_search_results') do
        find('li', text: /#{guardian.full_name}/i, wait: 5).click
      end

      assert_selector "input[type='hidden'][name='guardian_id']", visible: :all, wait: 5

      # Expose dependent fields directly for the form-state assertions.
      page.execute_script(<<~JS)
        var dependentSections = document.querySelector('[data-applicant-type-target="sectionsForDependentWithGuardian"]');
        if (dependentSections) {
          dependentSections.classList.remove('hidden');
          dependentSections.style.display = 'block';
          // Enable all form fields in the section
          var formFields = dependentSections.querySelectorAll('input, select, textarea');
          formFields.forEach(field => {
            field.disabled = false;
            field.removeAttribute('disabled');
          });
        }
      JS

      wait_for_stimulus_controller('applicant-type', timeout: 10)
      wait_for_stimulus_controller('paper-application', timeout: 10)
      wait_for_network_idle(timeout: 3)
      dependent_fieldset = page.find('fieldset', text: 'New Dependent Information', visible: true)
      within dependent_fieldset do
        assert_selector 'input[name="constituent[date_of_birth]"]:not([disabled])', wait: 10
      end

      dependent_fieldset = page.find('fieldset', text: 'New Dependent Information', visible: true)
      within dependent_fieldset do
        assert_selector 'input[name="constituent[first_name]"]:not([disabled])', wait: 5
        assert_selector 'input[name="constituent[date_of_birth]"]:not([disabled])', wait: 3

        fill_in 'constituent[first_name]', with: 'Xavier'
        fill_in 'constituent[last_name]', with: 'Collins'
        fill_in 'constituent[date_of_birth]', with: '09/09/1999'

        check 'use_guardian_email'
        check 'use_guardian_address'
      end

      page.execute_script(<<~JS)
        var commonSections = document.querySelector('[data-applicant-type-target="commonSections"]');
        if (commonSections) {
          commonSections.classList.remove('hidden');
          commonSections.style.display = 'block';
          // Enable all form fields in the section
          var formFields = commonSections.querySelectorAll('input, select, textarea');
          formFields.forEach(field => {
            field.disabled = false;
            field.removeAttribute('disabled');
          });
        }
      JS

      disability_fieldset = page.find('fieldset', text: /Disability Information.*for the Applicant/i, visible: true)
      within disability_fieldset do
        check 'applicant_attributes[self_certify_disability]'
        check 'applicant_attributes[hearing_disability]'
      end

      select 'Parent', from: 'relationship_type'

      provider_fieldset = page.find('fieldset', text: 'Certifying Professional Information', visible: true)
      within provider_fieldset do
        fill_in 'application_certifying_professional_name', with: 'doctor'
        fill_in 'application_certifying_professional_phone', with: '2027775656'
        fill_in 'application_certifying_professional_email', with: 'doc@tor.net'
      end

      proof_scans = {}
      proof_fieldset = page.find('section', text: 'Proof Documents', visible: true)
      within proof_fieldset do
        choose 'accept_income_proof', allow_label_click: true

        fill_in 'application_household_size', with: '5'
        fill_in 'application_annual_income', with: '29999'

        proof_scans[:income_proof] = attach_cleared_document 'income_proof', Rails.root.join('test/fixtures/files/income_proof.pdf')

        check 'application_maryland_resident'
        choose 'accept_residency_proof', allow_label_click: true
        proof_scans[:residency_proof] = attach_cleared_document 'residency_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')

        choose 'accept_id_proof', allow_label_click: true
        proof_scans[:id_proof] = attach_cleared_document 'id_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
      end

      # This test inspects the completed form without submitting it.
      complete_paper_application_attestations
      assert_button 'Submit Paper Application', disabled: false, wait: 10

      wait_for_stimulus_controller('paper-application', timeout: 10)
      wait_for_network_idle(timeout: 5)

      assert_field 'constituent[first_name]', with: 'Xavier', wait: 5
      assert_field 'constituent[last_name]', with: 'Collins', wait: 5
      assert_field 'constituent[date_of_birth]', with: '09/09/1999', wait: 5
      assert find_field('use_guardian_email').checked?
      assert find_field('use_guardian_address').checked?
      assert find_field('applicant_attributes[hearing_disability]').checked?
      assert_field 'application[household_size]', with: '5'
      assert_field 'application[annual_income]', with: '29999'
      assert find_field('application[maryland_resident]').checked?
      assert_field 'application[certifying_professional_name]', with: 'doctor'
      assert_field 'application[certifying_professional_phone]', with: '2027775656'
      assert_field 'application[certifying_professional_email]', with: 'doc@tor.net'
      assert find_field('accept_income_proof').checked?
      assert find_field('accept_residency_proof').checked?
      proof_scans.each do |field, scan|
        reference = find("input[type='hidden'][name='#{field}']", visible: :all).value
        assert_equal scan.blob_id, ActiveStorage::Blob.find_signed!(reference).id
        assert_equal 'clean', scan.reload.status
        assert_equal '', find_field(field.to_s, visible: :all).value
      end
      page.scroll_to(:top)
      take_screenshot('admin-dependent-paper-form-cleared-documents', html: true, full: true)
    end

    test 'approved admission remains ineligible in the adult picker after its waiting duration' do
      constituent = create(:constituent, first_name: 'Approved', last_name: 'Admission')
      create(:application, :approved, user: constituent, application_date: 5.years.ago)

      safe_visit new_admin_paper_application_path
      fill_in 'adult_search_q', with: constituent.full_name

      within '#adult_search_results' do
        result = find('li[aria-disabled="true"]', text: constituent.full_name, wait: 10)
        assert_equal 'Ineligible', result.find('span', text: 'Ineligible').text
        assert_text 'Has active application'
        result.click
      end
      assert_no_selector '[data-adult-picker-target="selectedPane"]', text: 'Applicant Selected'
      take_evidence_screenshot('checkpoint2-approved-adult-blocked', full: true, html: true)
    end

    test 'recent rejection permits adult admission and selecting its ordinary record' do
      constituent = create(:constituent, first_name: 'Rejected', last_name: 'Admission')
      create(:application, :rejected, user: constituent, application_date: 1.day.ago)

      safe_visit new_admin_paper_application_path
      fill_in 'adult_search_q', with: constituent.full_name

      within '#adult_search_results' do
        result = find('li[data-user-eligible="true"]', text: constituent.full_name, wait: 10)
        assert_equal 'Eligible', result.find('span', text: 'Eligible').text
        result.click
      end
      assert_selector '[data-adult-picker-target="selectedPane"]', text: constituent.full_name, wait: 10
      assert_field 'constituent[first_name]', with: constituent.first_name
      take_evidence_screenshot('checkpoint2-rejected-adult-selected', full: true, html: true)
    end

    test 'form validation prevents submission without required proof selections' do
      safe_visit new_admin_paper_application_path
      wait_for_page_load

      choose 'An Adult (applying for themselves)'
      reveal_adult_application_sections
      assert_selector '#self-info-section', text: "Applicant's Information", wait: 5

      within '#self-info-section' do
        fill_in 'constituent[first_name]', with: 'John'
        fill_in 'constituent[last_name]', with: 'Doe'
        fill_in 'constituent[date_of_birth]', with: '01/15/1980'
        fill_in 'constituent[email]', with: "john.doe.#{Time.now.to_i}@example.com"
        fill_in 'constituent[phone]', with: '555-123-4567'
        fill_in 'constituent[physical_address_1]', with: '123 Test St'
        fill_in 'constituent[city]', with: 'Baltimore'
        fill_in 'constituent[zip_code]', with: '21201'
      end

      within 'fieldset', text: 'Disability Information' do
        check 'applicant_attributes[self_certify_disability]'
        check 'applicant_attributes[hearing_disability]'
      end

      within 'fieldset', text: 'Certifying Professional Information' do
        fill_in 'application[certifying_professional_name]', with: 'Dr. Test'
        fill_in 'application[certifying_professional_phone]', with: '555-999-8888'
        fill_in 'application[certifying_professional_email]', with: 'dr.test@example.com'
      end

      # Valid income alone does not satisfy the final submit gate.
      assert_button 'Submit Paper Application', disabled: true

      # The visible gate status names the outstanding authorization rather than only disabling the button.
      assert_selector '#paper-submit-gate-status', text: /I authorize the release and sharing of my disability-related information/, wait: 5

      check 'application[maryland_resident]'
      check 'application[disability_information_release_authorized]'
      check 'application[terms_accepted]'
      check 'application[information_verified]'

      choose 'upload_only_income_proof'
      attach_cleared_document 'income_proof', Rails.root.join('test/fixtures/files/disability_certification_valid.pdf')

      choose 'upload_only_residency_proof'
      attach_cleared_document 'residency_proof', Rails.root.join('test/fixtures/files/disability_certification_valid.pdf')

      choose 'upload_only_id_proof'
      attach_cleared_document 'id_proof', Rails.root.join('test/fixtures/files/disability_certification_valid.pdf')

      page.execute_script(<<~JS)
        const form = document.querySelector('form[data-controller~="paper-application"]');
        form?.dispatchEvent(new CustomEvent('income-validation:validated', {
          bubbles: true,
          detail: { exceedsThreshold: false }
        }));
        form?.dispatchEvent(new Event('change', { bubbles: true }));
      JS

      assert_button 'Submit Paper Application', disabled: false, wait: 10

      # Re-establish the blocked gate so the named-status state is captured as the test's last
      # interaction; a mid-test full-page capture degrades this Cuprite session until later
      # scan polls miss their assert window.
      uncheck 'application[disability_information_release_authorized]'
      assert_selector '#paper-submit-gate-status', text: /I authorize the release and sharing of my disability-related information/, wait: 5
      assert_button 'Submit Paper Application', disabled: true
      page.scroll_to(:top)
      take_screenshot('paper-gate-names-missing-release-authorization', html: true, full: true)
    end
  end
end
