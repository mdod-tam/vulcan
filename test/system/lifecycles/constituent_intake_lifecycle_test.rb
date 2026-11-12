# frozen_string_literal: true

require 'application_system_test_case'

class ConstituentIntakeLifecycleTest < ApplicationSystemTestCase
  include OnlineApplicationTestHelpers

  test 'a constituent saves incomplete intake, resumes it, corrects eligibility, and submits the same application' do
    applicant = create(:constituent)
    setup_fpl_policies
    system_test_sign_in(applicant)
    visit new_constituent_portal_application_path
    assert_selector 'h1', text: 'New Application'

    fill_in_complete_online_application
    %w[Hearing Vision Speech Mobility Cognition].each { |label| uncheck label }
    assert_selector 'input[name="submit_application"]:disabled'
    save_online_application_draft
    application = Application.where(user: applicant).sole
    assert_equal 'draft', application.status
    assert_equal 2, application.household_size
    assert_equal 50_000, application.annual_income
    assert_current_path constituent_portal_application_path(application, format: :html)

    visit edit_constituent_portal_application_path(application)
    assert_field 'Household Size', with: '2'
    assert_equal 50_000, find_field('Annual Income').value.to_f
    %w[Hearing Vision Speech Mobility Cognition].each { |label| refute_checked_field label }
    assert_selector 'input[name="submit_application"]:disabled'

    check 'Hearing'
    accept_submit_confirmations
    wait_for_fpl_data_to_load(timeout: 15)
    assert_selector 'input[name="submit_application"]:not([disabled])'

    fill_in 'Annual Income', with: 100_000
    find_field('Annual Income').send_keys(:tab)
    assert_selector '#income-threshold-warning', text: 'Income Exceeds Threshold'
    assert_selector 'input[name="submit_application"]:disabled'

    fill_in 'Annual Income', with: 50_000
    find_field('Annual Income').send_keys(:tab)
    assert_selector '#income-threshold-warning[hidden]', visible: :all
    %w[Vision Speech Mobility Cognition].each { |label| check label }
    assert_selector 'input[name="submit_application"]:not([disabled])'
    click_button 'Submit Application'
    assert_success_message('Application submitted successfully')
    assert_equal [application.id], Application.where(user: applicant).pluck(:id), 'resuming intake must update its draft'
    assert_not_equal 'draft', application.reload.status
    applicant.reload
    %w[hearing vision speech mobility cognition].each do |disability|
      assert applicant.public_send("#{disability}_disability"), "#{disability} must be saved for the applicant"
    end
    %i[income_proof residency_proof id_proof].each do |proof|
      assert application.public_send(proof).attached?, "#{proof} must survive saving and resuming intake"
    end
    assert_empty page.evaluate_script('window.__systemTestErrors')
    take_screenshot('constituent-intake-submitted', full: true, html: true)
  end
end
