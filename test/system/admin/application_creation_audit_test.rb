# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'

module Admin
  class ApplicationCreationAuditTest < ApplicationSystemTestCase
    include ActiveStorageHelper
    include OnlineApplicationTestHelpers
    include PaperApplicationsTestHelper

    setup do
      @admin = create(:admin)
      @constituent = create(:constituent)
      setup_active_storage_test

      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_2_person').update(value: 21_150)
      Policy.find_or_create_by(key: 'fpl_3_person').update(value: 26_650)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)
    end

    teardown do
      clear_active_storage
    end

    test 'admin can see application creation event for online applications' do
      sign_out
      sign_in(@constituent)

      visit new_constituent_portal_application_path
      fill_in_complete_online_application
      wait_for_fpl_data_to_load(timeout: 15)
      click_button 'Submit Application'

      assert_success_message('Application submitted successfully')

      sign_out
      # The session reset clears any stored location.
      Capybara.reset_sessions!

      sign_in(@admin)

      visit admin_applications_path

      view_link = nil
      within 'table' do
        row = first('tr', text: @constituent.email)
        within row do
          view_link = find_link('View Application')
        end
      end

      application_path = view_link[:href]
      visit application_path

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
      sign_in(@admin)
      start_new_adult_paper_application
      fill_in_applicant_information(first_name: 'John', last_name: 'Paper', email: 'john.paper@example.com', phone: '555-987-6543')
      attach_and_accept_proofs
      fill_in_application_details(household_size: 3, annual_income: 45_000)
      fill_in_disability_information
      fill_in_medical_provider_information(name: 'Dr. Jones', email: 'jones@example.com')
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
