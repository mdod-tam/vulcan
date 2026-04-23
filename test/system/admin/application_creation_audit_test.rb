# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ApplicationCreationAuditTest < ApplicationSystemTestCase
    include ActiveStorageHelper

    setup do
      @admin = create(:admin)
      @constituent = create(:constituent)
      setup_active_storage_test

      # Set up FPL policies for testing
      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_2_person').update(value: 21_150)
      Policy.find_or_create_by(key: 'fpl_3_person').update(value: 26_650)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)
    end

    teardown do
      clear_active_storage
    end

    test 'admin can see application creation event for online applications' do
      # First create an application as a constituent
      sign_out
      sign_in(@constituent)

      visit new_constituent_portal_application_path

      # Fill in minimum required fields
      fill_in 'Household Size', with: '2'
      fill_in 'Annual Income', with: '30000'
      check 'I certify that I am a resident of Maryland'
      check 'I certify that I have a disability that affects my ability to access telecommunications services'

      # Fill in medical provider info
      within('section', text: 'Certifying Professional Information and Authorization to Contact') do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Email', with: 'smith@example.com'
        fill_in 'Phone', with: '555-123-4567'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      # Submit the form instead of saving as draft
      click_button 'Submit Application'

      # Verify application was submitted
      assert_text 'Application submitted successfully'

      # Sign out and sign in as admin
      sign_out
      # Reset the entire session to clear any stored location
      Capybara.reset_sessions!

      # Sign in as admin
      sign_in(@admin)

      # Find and view the application
      visit admin_applications_path

      # Find the "View" link for the application and get the href
      view_link = nil
      within 'table' do
        row = first('tr', text: @constituent.email)
        within row do
          view_link = find_link('View Application')
        end
      end

      # Navigate directly to the application path for more reliable navigation
      application_path = view_link[:href]
      visit application_path

      # Wait for Turbo navigation to complete
      wait_for_turbo

      # Wait for the application show page to load - verify we're on the right page
      assert_selector 'h1', text: /Application.*Details/i, wait: 15

      # Verify the audit log shows the application creation
      # Wait for the audit log section to be present and populated
      assert_selector '#audit-logs', wait: 10

      # Use Capybara's intelligent waiting to wait for the specific audit log text to appear
      # This handles the timing between application submission and audit log updates
      within '#audit-logs' do
        assert_text 'Application created via Online method with status: Draft', wait: 10
        assert_text 'Application created via Online method'
        assert_text 'Application submitted for review'
      end
    end

    test 'admin can see application creation event for paper applications' do
      # Sign in as admin for this test
      sign_in(@admin)
      # Create a paper application
      visit new_admin_paper_application_path

      # Select applicant type first to make form fields visible
      choose 'An Adult (applying for themselves)'
      click_button 'Create New Applicant'

      # Fill in constituent info
      within '#self-info-section' do
        fill_in 'First Name', with: 'John'
        fill_in 'Last Name', with: 'Paper'
        fill_in 'Date of Birth', with: '1980-01-15'
        check 'I accept the terms and conditions'
        fill_in 'Email Address', with: 'john.paper@example.com'
        fill_in 'Phone Number', with: '555-987-6543'
        fill_in 'Street Address', with: '123 Paper St'
        fill_in 'City', with: 'Baltimore'
        fill_in 'ZIP Code', with: '21201'
      end

      # Wait for the application fields to become visible after selecting applicant type
      assert_selector '[data-applicant-type-target="commonSections"]:not(.hidden)', wait: 5

      # Fill in application info (these fields are in the main form)
      fill_in 'Household Size', with: '3'
      fill_in 'Annual Income', with: '45000'
      check 'The applicant has marked that they are a resident of Maryland'
      check 'The applicant certifies that they have a disability that affects their ability to access telecommunications services'
      check 'Hearing'

      # Fill in medical provider info
      within('fieldset', text: 'Certifying Professional Information') do
        fill_in 'Provider Name', with: 'Dr. Jones'
        fill_in 'Email', with: 'jones@example.com'
        fill_in 'Phone', with: '555-333-4444'
        check 'I authorize medical release'
      end

      # Upload proof documents
      attach_file 'income_proof', Rails.root.join('test/fixtures/files/income_proof.pdf')
      attach_file 'residency_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')

      # Submit the form
      click_button 'Submit Paper Application'

      # Verify we landed on the created paper application's detail page
      assert_text(/Application #\d+ Details/i, wait: 10)

      # Verify the audit log shows the application creation
      within '#audit-logs' do
        assert_text 'Application Created (Paper)'
        assert_text 'Application created via Paper method'
      end
    end
  end
end
