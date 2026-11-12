# frozen_string_literal: true

require 'application_system_test_case'

class PaperIntakeLifecycleTest < ApplicationSystemTestCase
  include PaperApplicationsTestHelper

  setup do
    @admin = create(:admin)
    system_test_sign_in(@admin, bypass_mfa_enrollment: true)
    setup_fpl_policies
  end

  test 'staff open adult intake, enter documents and confirmations, and submit an approved application' do
    start_new_adult_paper_application
    applicant_email = "paper-lifecycle-#{SecureRandom.hex(5)}@example.com"
    ['Income Proof', 'Residency Proof', 'ID Proof', 'Disability Certification'].each do |proof|
      assert_selector 'fieldset', text: /#{Regexp.escape(proof)} Action.*Upload for later review/m
    end
    fill_in_applicant_information(email: applicant_email)
    fill_in_application_details(household_size: 1, annual_income: 15_000)
    fill_in_disability_information
    fill_in_certifying_professional_information
    assert_button 'Submit Paper Application', disabled: true

    attach_and_accept_proofs
    complete_paper_application_attestations
    assert_button 'Submit Paper Application', disabled: false

    assert_difference ['Application.count', 'Users::Constituent.count'], 1 do
      click_button 'Submit Paper Application'
      assert_selector 'h1', text: /Application #\d+ Details/
    end
    assert_text 'Paper application successfully submitted.'
    application = Application.order(:id).last
    assert_equal applicant_email, application.user.email
    assert_equal 'John', application.user.first_name
    assert_equal 'approved', application.status
    %i[income_proof residency_proof id_proof disability_certification].each do |proof|
      assert_equal 'approved', application.public_send("#{proof}_status"), proof.to_s
      assert application.public_send(proof).attached?, "#{proof} must be stored"
    end
    assert_empty page.evaluate_script('window.__systemTestErrors')
    take_screenshot('paper-intake-approved', full: true, html: true)
  end

  test 'staff correct an income warning, cancel rejection, and then send the rejection without creating an application' do
    start_new_adult_paper_application
    applicant_email = "paper-lifecycle-#{SecureRandom.hex(5)}@example.com"
    fill_in_applicant_information(email: applicant_email)
    fill_in_application_details(household_size: 1, annual_income: 100_000)
    fill_in_disability_information
    fill_in_certifying_professional_information
    find_field('application[annual_income]').send_keys(:tab)
    assert_selector '[data-income-validation-target="warningContainer"]', text: 'Income Exceeds Threshold'
    assert_button 'Submit Paper Application', disabled: true
    assert_button 'Reject (Income Over Threshold)', disabled: false

    fill_in 'application[annual_income]', with: 15_000
    find_field('application[annual_income]').send_keys(:tab)
    assert_selector '[data-income-validation-target="warningContainer"][hidden]', visible: :all
    assert_button 'Submit Paper Application', disabled: true

    fill_in 'application[annual_income]', with: 100_000
    find_field('application[annual_income]').send_keys(:tab)
    click_button 'Reject (Income Over Threshold)'
    assert_selector 'dialog#rejection-modal[open]'
    within('dialog#rejection-modal') { click_button 'Cancel' }
    assert_no_selector 'dialog#rejection-modal[open]'
    assert_field 'constituent[email]', with: applicant_email

    assert_no_difference 'Application.count' do
      click_button 'Reject (Income Over Threshold)'
      within 'dialog#rejection-modal' do
        choose 'communication_preference_email'
        fill_in 'additional_notes', with: 'Income exceeds the current program threshold.'
        click_button 'Send Notification'
      end
      assert_current_path admin_applications_path
    end
    assert_success_message('Rejection notification has been sent')
    assert_empty page.evaluate_script('window.__systemTestErrors')
    take_screenshot('paper-intake-rejected', full: true, html: true)
  end
end
