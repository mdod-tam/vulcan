# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')
require_relative 'paper_applications_test_helper'

module Admin
  class PaperApplicationContactControlsTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper
    include SystemTestEvidence

    setup do
      @admin = create(:admin, email: "contact_controls_#{SecureRandom.hex(4)}@example.com")
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit new_admin_paper_application_path
      wait_for_turbo
    end

    test 'self applicant create-new flow exposes no-contact controls and Stimulus targets' do
      choose 'An Adult (applying for themselves)'
      wait_for_turbo

      click_button 'Create New Applicant'
      wait_for_turbo

      assert_selector '#no_email_address_checkbox', visible: true
      assert_selector '#no_phone_number_checkbox', visible: true
      assert_selector '[data-controller="contact-feedback"]', visible: :all
      assert_selector '[data-contact-feedback-target="emailWrapper"]', visible: true
      assert_selector '[data-contact-feedback-target="phoneWrapper"]', visible: true
      assert_selector '[data-contact-feedback-target="email"]', visible: true
      assert_selector '[data-contact-feedback-target="phone"]', visible: true
    end

    test 'adult context follows the current selection through delayed response and submission' do
      previous_adult = create(:constituent, first_name: 'Previous', last_name: 'ContextAdult',
                                            physical_address_1: '11 Previous Street', locale: 'en')
      current_adult = create(:constituent, first_name: 'Current', last_name: 'ContextAdult',
                                           physical_address_1: '22 Current Street', locale: 'es')
      create(:application, :archived, user: previous_adult, annual_income: 11_000,
                                      certifying_professional_name: 'Previous Professional')
      create(:application, :archived, user: current_adult, annual_income: 22_000,
                                      certifying_professional_name: 'Current Professional')

      page.execute_script(<<~JS)
        const originalFetch = window.fetch.bind(window);
        window.fetch = (input, options) => {
          if (String(input).includes('/admin/users/#{previous_adult.id}/adult_application_context')) {
            return new Promise((resolve, reject) => {
              window.releaseAdultContext = () => originalFetch(input, options).then(async response => {
                await response.clone().text();
                resolve(response);
              }, reject);
            });
          }
          return originalFetch(input, options);
        };
      JS

      select_existing_adult_through_the_ui(previous_adult)
      within('[data-adult-picker-target="selectedPane"]') { click_button 'Change Selection' }
      select_existing_adult_through_the_ui(current_adult)
      assert_field 'constituent[physical_address_1]', with: '22 Current Street'
      assert_selector 'select[name="constituent[locale]"] option[value="es"]:checked'

      page.evaluate_async_script(<<~JS)
        const done = arguments[0];
        window.releaseAdultContext().then(() => setTimeout(done, 0));
      JS

      assert_selector "input[name='existing_constituent_id'][value='#{current_adult.id}']", visible: :all
      assert_field 'constituent[physical_address_1]', with: '22 Current Street'
      assert_selector 'select[name="constituent[locale]"] option[value="es"]:checked'
      assert_selector '[data-adult-picker-target="onFileSummaryContent"]', text: current_adult.full_name
      choose 'Use on-file contact info'
      assert_field 'constituent[physical_address_1]', with: '22 Current Street', readonly: true
      choose 'Update from paper form'
      fill_in 'constituent[physical_address_1]', with: '23 Corrected Current Street'
      verify_existing_adult_contact
      take_evidence_screenshot('adult-context-current-selection', full: true, html: true)

      2.times do
        assert_no_difference 'Application.count' do
          page.execute_script(<<~JS)
            const form = document.querySelector('form[data-controller~="paper-application"]');
            form.dataset.contextRetry = 'pending';
            HTMLFormElement.prototype.submit.call(form);
          JS
          assert_no_selector 'form[data-context-retry="pending"]', visible: :all, wait: 20
          assert_selector '[data-adult-picker-restored-value="true"]', wait: 20
          assert_selector '[data-adult-picker-target="onFileSummaryContent"]', text: current_adult.full_name
          assert_field 'constituent[physical_address_1]', with: '23 Corrected Current Street'
          assert_selector 'select[name="constituent[locale]"] option[value="es"]:checked'
          assert_selector '[data-adult-picker-target="verificationCheckbox"]:checked'
        end
      end
      take_evidence_screenshot('adult-context-restored-corrections', full: true, html: true)

      within('[data-adult-picker-target="selectedPane"]') { click_button 'Change Selection' }
      select_existing_adult_through_the_ui(previous_adult)
      assert_field 'constituent[physical_address_1]', with: '11 Previous Street'
      assert_selector 'select[name="constituent[locale]"] option[value="en"]:checked'
      within('[data-adult-picker-target="selectedPane"]') { click_button 'Change Selection' }
      select_existing_adult_through_the_ui(current_adult)
      assert_field 'constituent[physical_address_1]', with: '22 Current Street'
      assert_selector 'select[name="constituent[locale]"] option[value="es"]:checked'
      fill_in 'constituent[physical_address_1]', with: '23 Corrected Current Street'
      verify_existing_adult_contact
      take_evidence_screenshot('adult-context-replaced-after-retry', full: true, html: true)

      fill_in_application_details(household_size: 1, annual_income: 15_000)
      fill_in_disability_information
      fill_in_certifying_professional_information
      attach_and_accept_proofs
      complete_paper_application_attestations
      assert_button 'Submit Paper Application', disabled: false, wait: 10
      click_button 'Submit Paper Application'
      assert_text 'Paper application successfully submitted.', wait: 20

      assert_equal current_adult.id, Application.order(:created_at).last.user_id
      assert_equal '23 Corrected Current Street', current_adult.reload.physical_address_1
      assert_equal 'es', current_adult.locale
      assert_equal '11 Previous Street', previous_adult.reload.physical_address_1
      assert_equal 'en', previous_adult.locale
      take_evidence_screenshot('adult-context-selection-submitted', full: true, html: true)
    end
  end
end
