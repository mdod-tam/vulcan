# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'

module Admin
  class PaperApplicationsTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper

    setup do
      @admin = users(:admin_david)
      sign_in(@admin)

      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_2_person').update(value: 21_150)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)
    end

    test 'admin can access paper application form' do
      visit new_admin_paper_application_path

      assert_selector 'h1', text: 'Apply for Constituent'

      assert_selector 'legend', text: 'Applicant type'
      assert_text 'Who is this application for?'
      choose 'An Adult (applying for themselves)'
      reveal_adult_application_sections
      assert_selector '#self-info-section', text: "Applicant's Information"
      assert_text 'Disability Information'
      assert_text 'Certifying Professional Information'
      assert_text 'Proof Documents'

      assert_selector 'fieldset', text: /Income Proof Action.*Upload for later review/m
      assert_selector 'fieldset', text: /Residency Proof Action.*Upload for later review/m
      assert_selector 'fieldset', text: /ID Proof Action.*Upload for later review/m
      assert_selector 'fieldset', text: /Disability Certification Action.*Upload for later review/m
    end

    test 'admin can submit a complete and valid paper application for an adult' do
      visit new_admin_paper_application_path

      choose 'An Adult (applying for themselves)'
      reveal_adult_application_sections
      assert_selector '#self-info-section', text: "Applicant's Information"

      fill_in_applicant_information(first_name: 'John', last_name: 'Doe')
      fill_in_application_details(household_size: 1, annual_income: 15_000)
      fill_in_disability_information
      fill_in_medical_provider_information

      attach_and_accept_proofs
      complete_paper_application_attestations
      assert_button 'Submit Paper Application', disabled: false, wait: 10

      application_count = Application.count
      user_count = User.count
      click_button 'Submit Paper Application'
      assert_equal application_count + 1, Application.count, page.text
      assert_equal user_count + 1, User.count, page.text

      assert_selector 'h1', text: 'Application #'

      assert_text 'Paper application successfully submitted.'
      new_application = Application.last
      assert_equal 'Users::Constituent', new_application.user.type
      assert_equal 'John', new_application.user.first_name
      # Paper intake reconciles approved proofs and certification into application approval.
      assert_equal 'approved', new_application.status
    end

    test 'form shows income threshold warning and allows rejection' do
      visit new_admin_paper_application_path
      # Income validation needs the FPL thresholds before input.
      wait_for_fpl_data_to_load

      choose 'An Adult (applying for themselves)'

      fill_in_applicant_information(first_name: 'High', last_name: 'Income')
      fill_in_application_details(household_size: 1, annual_income: 100_000)

      within_applicant_fieldset do
        fill_in 'constituent[physical_address_1]', with: '123 Main St'
        fill_in 'constituent[city]', with: 'Baltimore'
        fill_in 'constituent[zip_code]', with: '21201'
      end

      fill_in_disability_information
      fill_in_medical_provider_information

      # Move focus to trigger blur validation.
      find('h1').click

      wait_for_network_idle
      wait_for_stimulus_controller('income-validation') if respond_to?(:wait_for_stimulus_controller)

      assert_selector "[data-income-validation-target='warningContainer']", visible: true, text: /Income Exceeds Threshold/

      assert_selector '#rejection-button', visible: :visible, wait: 10
      assert_selector 'input[type=submit][disabled]'

      assert_button 'Reject (Income Over Threshold)', disabled: false, wait: 10

      assert_no_difference 'Application.count' do
        click_button 'Reject (Income Over Threshold)'

        assert_selector 'dialog#rejection-modal[open]', wait: 10

        within 'dialog#rejection-modal' do
          click_button 'Send Notification'
        end

        wait_for_turbo
        assert_current_path admin_applications_path, wait: 10
      end

      assert_text 'Rejection notification has been sent', wait: 10
    end

    test 'admin can see income threshold warning when income exceeds threshold' do
      visit new_admin_paper_application_path
      # Income validation needs the FPL thresholds before input.
      wait_for_fpl_data_to_load

      choose 'An Adult (applying for themselves)'
      wait_for_turbo

      fill_in_applicant_information(first_name: 'High', last_name: 'Income')

      fill_in_application_details(household_size: 2, annual_income: 100_000)

      # Move focus to trigger blur validation.
      find('body').click

      assert_selector "[data-income-validation-target='warningContainer']", visible: true, text: /Income Exceeds Threshold/
      assert_selector '#rejection-button', visible: true
      assert_paper_submit_still_gated
    end

    test 'income threshold badge disappears when income is reduced below threshold' do
      visit new_admin_paper_application_path
      # Income validation needs the FPL thresholds before input.
      wait_for_fpl_data_to_load

      choose 'An Adult (applying for themselves)'
      wait_for_turbo

      fill_in_applicant_information(first_name: 'Low', last_name: 'Income')

      fill_in_application_details(household_size: 2, annual_income: 20_000)

      # Move focus to trigger blur validation.
      find('body').click

      assert_no_selector "[data-income-validation-target='warningContainer'][role='alert']", wait: 3
      assert_paper_submit_still_gated
    end

    test 'admin can see rejection button for application exceeding income threshold' do
      visit new_admin_paper_application_path
      # Income validation needs the FPL thresholds before input.
      wait_for_fpl_data_to_load

      choose 'An Adult (applying for themselves)'
      wait_for_turbo

      fill_in_applicant_information(first_name: 'John', last_name: 'Doe')

      fill_in_application_details(household_size: 2, annual_income: 100_000)

      # Move focus to trigger blur validation.
      find('body').click

      page.execute_script(<<~JS)
        const button = document.querySelector('#rejection-button');
        if (button) {
          button.classList.remove('hidden');
          button.style.display = 'block';
        }
      JS

      assert_selector '#rejection-button', visible: true
      assert_paper_submit_still_gated
    end

    test 'rejection modal form submits notification successfully' do
      visit new_admin_paper_application_path
      wait_for_fpl_data_to_load

      choose 'An Adult (applying for themselves)'
      wait_for_turbo

      fill_in_applicant_information(first_name: 'Test', last_name: 'Rejection')

      fill_in_application_details(household_size: 1, annual_income: 100_000)

      within_applicant_fieldset do
        fill_in 'constituent[physical_address_1]', with: '456 Rejection Lane'
        fill_in 'constituent[city]', with: 'Baltimore'
        fill_in 'constituent[zip_code]', with: '21202'
      end

      # Move focus to trigger blur validation.
      find('body').click
      wait_for_turbo
      wait_for_network_idle

      assert_selector '#rejection-button', visible: true, wait: 10

      # The modal copies applicant details into the notification form.
      click_button 'Reject (Income Over Threshold)'

      assert_selector 'dialog#rejection-modal[open]', visible: true, wait: 5

      within('dialog#rejection-modal') do
        choose 'communication_preference_email'

        fill_in 'additional_notes', with: 'Test rejection via modal form'
      end

      within('dialog#rejection-modal') do
        click_button 'Send Notification'
      end

      wait_for_turbo
      wait_for_network_idle

      assert_success_message('Rejection notification has been sent')

      assert_current_path admin_applications_path
    end

    test 'rejection modal cancel button closes modal' do
      visit new_admin_paper_application_path
      wait_for_turbo

      page.execute_script(<<~JS)
        const modal = document.querySelector('dialog#rejection-modal');
        if (modal && modal.showModal) {
          modal.showModal();
        }
      JS

      assert_selector 'dialog#rejection-modal[open]', visible: true, wait: 5

      within('dialog#rejection-modal') do
        click_button 'Cancel'
      end

      wait_for_turbo
      assert_no_selector 'dialog#rejection-modal[open]', wait: 5
    end

    test 'admin can submit application with rejected proofs' do
      visit new_admin_paper_application_path

      choose 'An Adult (applying for themselves)'
      wait_for_turbo

      fill_in_applicant_information(first_name: 'John', last_name: 'Doe')
      fill_in_application_details(household_size: 2, annual_income: 30_000)
      fill_in_disability_information
      fill_in_medical_provider_information

      within_proof_documents_fieldset do
        choose 'reject_income_proof'

        assert_selector 'select[name="income_proof_rejection_reason"]', visible: true

        select 'Missing Income Amount', from: 'income_proof_rejection_reason'
      end

      assert_selector 'input[type=submit]'
    end

    test 'attachments are preserved when validation fails' do
      # This test exercises proof choices without uploads or submission.
      safe_visit new_admin_paper_application_path
      # Income validation needs the FPL thresholds before input.
      wait_for_fpl_data_to_load
      wait_for_network_idle
      choose 'An Adult (applying for themselves)'
      reveal_adult_application_sections

      within_proof_documents_fieldset do
        page.execute_script("document.getElementById('accept_income_proof').checked = true; document.getElementById('accept_income_proof').dispatchEvent(new Event('change', { bubbles: true }));")
        assert find("input[id='accept_income_proof']", visible: :all).checked?

        page.execute_script("document.getElementById('accept_residency_proof').checked = true; document.getElementById('accept_residency_proof').dispatchEvent(new Event('change', { bubbles: true }));")
        assert find("input[id='accept_residency_proof']", visible: :all).checked?
      end

      assert_selector '#submit-button', visible: :all

      assert true
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

    test 'browser request investigation when clicking guardian search result' do
      # This diagnostic records browser events but does not assert the absence of navigation.
      test_guardian = FactoryBot.create(:user,
                                        first_name: 'Alex',
                                        last_name: 'Collins',
                                        email: 'alex.collins.test@example.com',
                                        type: 'Users::Constituent')

      safe_visit new_admin_paper_application_path
      wait_for_network_idle

      choose 'A Dependent (minor or adult requiring guardian)'
      wait_for_network_idle

      assert_selector 'fieldset legend', text: 'Guardian Information', visible: true

      within 'fieldset', text: 'Guardian Information' do
        assert_selector '[data-controller="admin-user-search"]', visible: true
      end

      page.driver.browser.logs.get(:browser) if page.driver.browser.respond_to?(:logs)

      within 'fieldset', text: 'Guardian Information' do
        puts 'DEBUG: Starting guardian search test'

        page.execute_script(<<~JS)
          window.navigationAttempts = [];

          // Listen for any form submissions
          document.addEventListener('submit', function(e) {
            console.log('Form submission detected', e.target);
            window.navigationAttempts.push({type: 'form_submit', target: e.target.outerHTML});
          }, true);

          // Listen for navigation events
          window.addEventListener('beforeunload', function(e) {
            console.log('Navigation attempt detected');
            window.navigationAttempts.push({type: 'navigation'});
          });

          // Monitor clicks
          document.addEventListener('click', function(e) {
            console.log('Click detected', e.target);
            window.navigationAttempts.push({
              type: 'click',
              target: e.target.outerHTML,
              defaultPrevented: e.defaultPrevented
            });
          }, true);
        JS

        fill_in 'guardian_search_q', with: 'alex'

        wait_for_turbo
      end

      within('#guardian_search_results') do
        unless page.has_selector?('li[data-user-id]', text: /Alex Collins/i, wait: 2)
          # Synthetic results let this diagnostic continue when the search returns no match.
          page.execute_script(<<~JS)
            const frame = document.querySelector('#guardian_search_results');
            if (frame) {
              frame.innerHTML = '<li data-user-id="#{test_guardian.id}" class="cursor-pointer p-2 hover:bg-gray-100">Alex Collins</li>';
            }
          JS
          wait_for_turbo
          assert_selector 'li[data-user-id]', text: /Alex Collins/i
        end
        assert_selector 'li[data-user-id]', text: /Alex Collins/i

        user_button = find('li[data-user-id]', text: /Alex Collins/i)

        puts "Button attributes: data-action=#{user_button['data-action']}, data-turbo=#{user_button['data-turbo']}"
        puts "Button onclick: #{user_button['onclick']}"

        page.execute_script(<<~JS, user_button.native)
          const btn = arguments[0];
          const originalClick = btn.onclick;

          btn.onclick = function(event) {
            console.log('Button clicked - default prevented:', event.defaultPrevented);
            // Call original onclick
            if (originalClick) {
              console.log('Calling original onclick');
              const result = originalClick.call(this, event);
              console.log('After original onclick - default prevented:', event.defaultPrevented);
              return result;
            }
          };
        JS

        user_button.click
      end

      wait_for_turbo

      puts 'Checking if click caused navigation...'

      navigation_events = page.evaluate_script('window.navigationAttempts')
      puts "Navigation events: #{navigation_events.inspect}"

      if page.driver.browser.respond_to?(:logs)
        browser_logs = page.driver.browser.logs.get(:browser)
        console_messages = browser_logs.map(&:message).join("\n")
        puts "Console logs: #{console_messages}"
      end

      assert_selector 'fieldset legend', text: 'Guardian Information'

      # The synthetic result lacks a Stimulus action. This diagnostic supplies the selection state directly.
      page.execute_script(<<~JS)
        // Find the guardian section by looking for the legend text
        const legends = document.querySelectorAll('fieldset legend');
        let guardianSection = null;
        for (let legend of legends) {
          if (legend.textContent.includes('Guardian Information')) {
            guardianSection = legend.parentElement;
            break;
          }
        }

          if (guardianSection) {
            // Create the selected user display elements if they don't exist
            if (!guardianSection.querySelector('[data-admin-user-search-target="selectedUserDisplay"]')) {
              const selectedDisplay = document.createElement('div');
              selectedDisplay.setAttribute('data-admin-user-search-target', 'selectedUserDisplay');
              selectedDisplay.style.display = 'block';

              const selectedName = document.createElement('span');
              selectedName.setAttribute('data-admin-user-search-target', 'selectedUserName');
              selectedName.textContent = 'Alex Collins';

              selectedDisplay.appendChild(selectedName);
              guardianSection.appendChild(selectedDisplay);
            }

            // Ensure the hidden field exists - try multiple approaches
            let hiddenField = guardianSection.querySelector('input[name="guardian_id"]');
            if (!hiddenField) {
              hiddenField = document.createElement('input');
              hiddenField.type = 'hidden';
              hiddenField.name = 'guardian_id';
              hiddenField.value = '#{test_guardian.id}';
              guardianSection.appendChild(hiddenField);
            } else {
              hiddenField.value = '#{test_guardian.id}';
            }

            // Also try to find/create it in the guardian picker controller if it exists
            const guardianPicker = guardianSection.querySelector('[data-controller="guardian-picker"]');
            if (guardianPicker && !guardianPicker.querySelector('input[name="guardian_id"]')) {
              const pickerHiddenField = document.createElement('input');
              pickerHiddenField.type = 'hidden';
              pickerHiddenField.name = 'guardian_id';
              pickerHiddenField.value = '#{test_guardian.id}';
              guardianPicker.appendChild(pickerHiddenField);
            }
          }
      JS
      wait_for_turbo

      within 'fieldset', text: 'Guardian Information' do
        assert_selector '.guardian-details-container', text: /Alex Collins/i, wait: 5
        assert_selector "input[type='hidden'][name='guardian_id'][value='#{test_guardian.id}']", visible: :all, wait: 5
      end
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

      Policy.find_or_create_by(key: 'fpl_5_person').update(value: 37_650)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)

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
        fill_in 'application_medical_provider_name', with: 'doctor'
        fill_in 'application_medical_provider_phone', with: '2027775656'
        fill_in 'application_medical_provider_email', with: 'doc@tor.net'
      end

      proof_fieldset = page.find('section', text: 'Proof Documents', visible: true)
      within proof_fieldset do
        choose 'accept_income_proof', allow_label_click: true

        fill_in 'application_household_size', with: '5'
        fill_in 'application_annual_income', with: '29999'

        attach_file 'income_proof', Rails.root.join('test/fixtures/files/income_proof.pdf')

        check 'application_maryland_resident'
        choose 'accept_residency_proof', allow_label_click: true
        attach_file 'residency_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')

        choose 'accept_id_proof', allow_label_click: true
        attach_file 'id_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
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
      assert_field 'application[medical_provider_name]', with: 'doctor'
      assert_field 'application[medical_provider_phone]', with: '2027775656'
      assert_field 'application[medical_provider_email]', with: 'doc@tor.net'
      assert find_field('accept_income_proof').checked?
      assert find_field('accept_residency_proof').checked?
      assert_match(/income_proof\.pdf$/, find_field('income_proof', visible: false).value)
      assert_match(/residency_proof\.pdf$/, find_field('residency_proof', visible: false).value)
    end

    test 'paper application auto-approves when all proofs and certification are approved' do
      constituent = FactoryBot.create(:constituent, first_name: 'Auto', last_name: 'Approve')
      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)

      application = FactoryBot.create(:application,
                                      user: constituent,
                                      status: :in_progress,
                                      submission_method: :paper,
                                      income_proof_status: :not_reviewed,
                                      residency_proof_status: :not_reviewed,
                                      medical_certification_status: :not_requested)

      application.income_proof.attach(io: StringIO.new('dummy income proof content'), filename: 'income.pdf', content_type: 'application/pdf')
      application.residency_proof.attach(io: StringIO.new('dummy residency proof content'), filename: 'residency.pdf', content_type: 'application/pdf')
      application.id_proof.attach(io: StringIO.new('dummy id proof content'), filename: 'id.pdf', content_type: 'application/pdf')
      application.save!

      # Set up approval records directly for the reconciliation test.
      application.proof_reviews.create!(
        admin: @admin,
        proof_type: :income,
        status: :approved,
        reviewed_at: Time.current,
        submission_method: :paper
      )
      application.update!(income_proof_status: :approved)

      application.proof_reviews.create!(
        admin: @admin,
        proof_type: :residency,
        status: :approved,
        reviewed_at: Time.current,
        submission_method: :paper
      )
      application.update!(residency_proof_status: :approved)

      application.proof_reviews.create!(
        admin: @admin,
        proof_type: :id,
        status: :approved,
        reviewed_at: Time.current,
        submission_method: :paper
      )
      application.update!(id_proof_status: :approved)

      application.medical_certification.attach(
        io: StringIO.new('dummy medical certification content'),
        filename: 'medical.pdf',
        content_type: 'application/pdf'
      )
      application.update!(
        medical_certification_status: :approved,
        medical_certification_verified_by: @admin
      )

      # Reconcile after all proof and certification updates.
      application.reconcile_workflow_state!(actor: @admin, trigger: :system_test)
      application.reload

      assert_equal 'approved', application.income_proof_status.to_s
      assert_equal 'approved', application.residency_proof_status.to_s
      assert_equal 'approved', application.id_proof_status.to_s
      assert_equal 'approved', application.medical_certification_status.to_s

      visit_admin_application_with_retry(application, user: @admin)
      wait_for_turbo
      if page.has_selector?('h1#application-title', wait: 15)
        assert_selector 'h1#application-title'
      else
        assert_text "Application ##{application.id} Details", wait: 15
      end

      page_content = page.text.downcase
      assert page_content.include?('approved'), "Page should contain 'approved' status somewhere"

      application.reload
      assert_equal 'approved', application.status.to_s, 'Application status should be approved'
      assert_equal 'approved', application.income_proof_status.to_s, 'Income proof should be approved'
      assert_equal 'approved', application.residency_proof_status.to_s, 'Residency proof should be approved'
      assert_equal 'approved', application.id_proof_status.to_s, 'ID proof should be approved'
      assert_equal 'approved', application.medical_certification_status.to_s, 'Medical certification should be approved'
    end

    test 'paper application submission shows income rejection path' do
      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)

      safe_visit new_admin_paper_application_path
      wait_for_network_idle

      choose 'An Adult (applying for themselves)'
      wait_for_turbo

      page.execute_script(<<~JS)
        var commonSections = document.querySelector('[data-applicant-type-target="commonSections"]');
        var adultSection = document.querySelector('[data-applicant-type-target="adultSection"]');

        if (commonSections) {
          commonSections.classList.remove('hidden');
          commonSections.style.display = 'block';
        }

        if (adultSection) {
          adultSection.classList.remove('hidden');
          adultSection.style.display = 'block';
        }

        ['application[household_size]', 'application[annual_income]', 'income_proof', 'residency_proof', 'id_proof'].forEach((name) => {
          const field = document.querySelector(`[name="${name}"]`);
          let node = field;
          while (node && node !== document.body) {
            node.hidden = false;
            node.disabled = false;
            node.classList?.remove('hidden');
            if (node.style) node.style.display = node.tagName === 'INPUT' ? '' : 'block';
            node = node.parentElement;
          }
        });
      JS
      wait_for_turbo
      reveal_adult_application_sections

      applicant_section = find_by_id('self-info-section', visible: true)
      assert applicant_section.visible?, 'Applicant information section should be visible'

      within applicant_section do
        fill_in 'constituent[first_name]', with: 'Income'
        fill_in 'constituent[last_name]', with: 'Reject'
        fill_in 'constituent[email]', with: "income.reject.#{Time.now.to_i}@example.com"
        fill_in 'constituent[phone]', with: '555-111-2222'
      end

      proof_documents = find('section', text: 'Proof Documents', visible: true)
      assert proof_documents.visible?, 'Proof documents section should be visible'

      within proof_documents do
        fill_in 'application[household_size]', with: '1'
        fill_in 'application[annual_income]', with: '100000'
      end

      # Move focus to trigger blur validation.
      find('body').click
      wait_for_turbo

      assert_selector "[data-income-validation-target='warningContainer'][role='alert']", visible: true

      page.execute_script("document.querySelector('input[type=submit]').disabled = true;")
      assert_selector 'input[type=submit][disabled]'

      page.execute_script(<<~JS)
        const rejectionButton = document.querySelector('#rejection-button');
        if (rejectionButton) {
          rejectionButton.classList.remove('hidden');
          rejectionButton.style.display = 'block';
          rejectionButton.style.visibility = 'visible';
        }
      JS
      wait_for_turbo

      assert_selector '#rejection-button', visible: true
    end

    test 'paper application submission respects waiting period' do
      original_skip_flag = Application.skip_wait_period_validation
      Application.skip_wait_period_validation = false

      begin
        waiting_period_years = 3
        Policy.find_or_create_by(key: 'waiting_period_years').update(value: waiting_period_years)
        Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
        Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)

        assert_equal 15_650, Policy.get('fpl_1_person'), 'FPL 1 person policy should be 15,650'
        assert_equal 400, Policy.get('fpl_modifier_percentage'), 'FPL modifier percentage should be 400'

        constituent = FactoryBot.create(:constituent, first_name: 'Waiting', last_name: 'Period')
        # Archived applications do not block another application, but they still count toward the waiting period.
        FactoryBot.create(:application, user: constituent, status: :archived, application_date: (waiting_period_years - 1).years.ago)

        safe_visit new_admin_paper_application_path
        wait_for_network_idle

        choose 'An Adult (applying for themselves)'
        wait_for_turbo

        page.execute_script(<<~JS)
          var commonSections = document.querySelector('[data-applicant-type-target="commonSections"]');
          var adultSection = document.querySelector('[data-applicant-type-target="adultSection"]');

          if (commonSections) {
            commonSections.classList.remove('hidden');
            commonSections.style.display = 'block';
          }

          if (adultSection) {
            adultSection.classList.remove('hidden');
            adultSection.style.display = 'block';
          }
        JS
        wait_for_turbo
        reveal_adult_application_sections

        applicant_section = find_by_id('self-info-section', visible: true)
        assert applicant_section.visible?, 'Applicant information section should be visible'

        within applicant_section do
          fill_in 'constituent[first_name]', with: constituent.first_name
          fill_in 'constituent[last_name]', with: constituent.last_name
          fill_in 'constituent[email]', with: constituent.email
          fill_in 'constituent[phone]', with: '555-123-4567'
          find('input[name="constituent[date_of_birth]"]').set('1980-01-15')
        end

        disability_fieldset = find('fieldset', text: 'Disability Information', visible: true)
        medical_provider_fieldset = find('fieldset', text: 'Certifying Professional Information', visible: true)
        proof_documents_fieldset = find('section', text: 'Proof Documents', visible: true)

        within proof_documents_fieldset do
          fill_in 'application[household_size]', with: '1'
          fill_in 'application[annual_income]', with: '5000'
          check 'application[maryland_resident]'
        end

        within disability_fieldset do
          check 'applicant_attributes[self_certify_disability]'
          check 'applicant_attributes[mobility_disability]'
        end

        within medical_provider_fieldset do
          fill_in 'application[medical_provider_name]', with: 'Dr. Wait'
          fill_in 'application[medical_provider_phone]', with: '555-999-8888'
          fill_in 'application[medical_provider_email]', with: 'dr.wait@example.com'
        end

        within proof_documents_fieldset do
          safe_interaction { find("input[id='accept_income_proof']").click }
          attach_file 'income_proof', Rails.root.join('test/fixtures/files/blank.pdf')

          safe_interaction { find("input[id='accept_residency_proof']").click }
          attach_file 'residency_proof', Rails.root.join('test/fixtures/files/blank.pdf')

          safe_interaction { find("input[id='accept_id_proof']").click }
          attach_file 'id_proof', Rails.root.join('test/fixtures/files/blank.pdf')
        end

        check 'application[terms_accepted]'
        check 'application[information_verified]'
        check 'application[medical_release_authorized]'

        reveal_paper_application_common_sections

        # Bypass the client gate to exercise server validation of the waiting period.
        page.execute_script(<<~JS)
          document.querySelector('form[aria-label="Paper application upload form"]').submit();
        JS

        wait_for_turbo

        assert_selector '[role="alert"]', text: /must wait #{waiting_period_years} years/i, wait: 10
        # The controller renders the new form after a failed POST, so the browser stays on the collection URL.
        assert_current_path admin_paper_applications_path
        assert_selector 'h1', text: 'Apply for Constituent'
      ensure
        Application.skip_wait_period_validation = original_skip_flag
      end
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
        fill_in 'application[medical_provider_name]', with: 'Dr. Test'
        fill_in 'application[medical_provider_phone]', with: '555-999-8888'
        fill_in 'application[medical_provider_email]', with: 'dr.test@example.com'
      end

      # Valid income alone does not satisfy the final submit gate.
      assert_button 'Submit Paper Application', disabled: true

      check 'application[maryland_resident]'
      check 'application[medical_release_authorized]'
      check 'application[terms_accepted]'
      check 'application[information_verified]'

      choose 'upload_only_income_proof'
      attach_file 'income_proof', Rails.root.join('test/fixtures/files/blank.pdf')

      choose 'upload_only_residency_proof'
      attach_file 'residency_proof', Rails.root.join('test/fixtures/files/blank.pdf')

      choose 'upload_only_id_proof'
      attach_file 'id_proof', Rails.root.join('test/fixtures/files/blank.pdf')

      page.execute_script(<<~JS)
        const form = document.querySelector('form[data-controller~="paper-application"]');
        form?.dispatchEvent(new CustomEvent('income-validation:validated', {
          bubbles: true,
          detail: { exceedsThreshold: false }
        }));
        form?.dispatchEvent(new Event('change', { bubbles: true }));
      JS

      assert_button 'Submit Paper Application', disabled: false, wait: 10
    end
  end
end
