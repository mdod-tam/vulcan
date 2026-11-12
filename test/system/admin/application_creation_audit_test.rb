# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ApplicationCreationAuditTest < ApplicationSystemTestCase
    include ActiveStorageHelper
    include OnlineApplicationTestHelpers
    include PaperApplicationsTestHelper

    setup do
      @admin = create(:admin)
      @constituent = create(:constituent)
      setup_active_storage_test

      setup_fpl_policies
    end

    teardown do
      clear_active_storage
    end

    test 'admin can see application creation event for online applications' do
      sign_in(@constituent)

      visit new_constituent_portal_application_path
      fill_in_complete_online_application
      wait_for_fpl_data_to_load(timeout: 15)
      click_button 'Submit Application'

      assert_success_message('Application submitted successfully')
      submitted_application = Application.find_by!(user: @constituent)

      system_test_switch_user(@admin, bypass_mfa_enrollment: true)

      visit admin_applications_path

      within 'table' do
        within 'tr', text: @constituent.email do
          find_link(href: admin_application_path(submitted_application, anchor: 'attachments-section')).click
        end
      end

      wait_for_turbo

      assert_selector 'h1', text: /Application.*Details/i, wait: 15

      assert_selector '#audit-logs', wait: 10

      within '#audit-logs' do
        assert_text 'Application created via Online method with status: Draft', wait: 10
        assert_text 'Application created via Online method'
        assert_text 'Application submitted for review'
      end
    end

    test 'admin can see application creation event for paper applications' do
      sign_in(@admin, bypass_mfa_enrollment: true)
      start_new_adult_paper_application
      fill_in_applicant_information(first_name: 'John', last_name: 'Paper', email: 'john.paper@example.com', phone: '555-987-6543')
      attach_and_accept_proofs
      fill_in_application_details(household_size: 3, annual_income: 45_000)
      fill_in_disability_information
      fill_in_certifying_professional_information(name: 'Dr. Jones', email: 'jones@example.com')
      complete_paper_application_attestations

      click_button 'Submit Paper Application'

      assert_text(/Application #\d+ Details/i, wait: 10)

      within '#audit-logs' do
        assert_text 'Application Created (Paper)'
        assert_text 'Application created via Paper method'
      end
    end
  end
end
