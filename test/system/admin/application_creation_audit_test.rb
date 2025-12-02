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
      within('section', text: 'Medical Professional Information') do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Email', with: 'smith@example.com'
        fill_in 'Phone', with: '555-123-4567'
        check 'I authorize the release and sharing of my medical information as described above'
      end

      # Submit the form instead of saving as draft
      click_button 'Submit Application'

      # Verify application was submitted
      assert_text 'Application submitted successfully'

      # Debug: Check if application was actually created
      created_application = Application.find_by(user: @constituent)
      puts "Created application: #{created_application.inspect}"
      puts "Application ID: #{created_application&.id}"
      puts "Application user: #{created_application&.user&.full_name}"
      puts "Application status: #{created_application&.status}"

      # Verify audit event with debug info
      events = Event.where(auditable: created_application).order(created_at: :desc)
      puts "Events for application #{created_application.id}:"
      events.each do |e|
        puts "- #{e.action} by #{e.user&.email} at #{e.created_at}: #{e.metadata.inspect}"
      end

      event = events.find { |e| e.action == 'application_created' }
      if event
        puts "Found application_created event: #{event.attributes}"
      else
        puts "ERROR: No application_created event found for application #{created_application.id}"
      end

      # Sign out and sign in as admin
      sign_out
      # Reset the entire session to clear any stored location
      Capybara.reset_sessions!

      # Sign in as admin
      sign_in(@admin)

      # Debug: Check admin authentication
      puts "Admin user: #{@admin.email}, admin?: #{@admin.admin?}"
      puts "Current URL after admin sign in: #{current_url}"
      puts "Page has admin content: #{page.has_content?('Dashboard')}"

      # Find and view the application
      visit admin_applications_path

      # Debug: Check what's on the admin applications page
      puts "Admin applications page URL: #{current_url}"
      puts "Page title: #{page.title}"
      puts "Page has applications: #{page.has_content?('Applications')}"
      puts "Page content (first 500 chars): #{page.text[0..500]}"

      # Check if there are any applications in the database
      puts "Total applications in DB: #{Application.count}"
      puts "Applications by user: #{Application.all.map { |a| "#{a.id}: #{a.user.full_name}" }}"

      # Debug: List all links on the page
      all_links = all('a').map(&:text)
      puts "All links on admin applications page: #{all_links}"

      # Find the "View" link for the application and get the href
      view_link = nil
      within 'table' do
        row = first('tr', text: @constituent.email)
        within row do
          view_link = find_link('View')
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
        # Wait for the audit log to show the in_progress status - Capybara will retry until timeout
        assert_text 'Application created via Online method with status: In Progress', wait: 10
        assert_text 'Application created via Online method'
      end
    end

    test 'admin can see application creation event for paper applications' do
      # Sign in as admin for this test
      sign_in(@admin)
      # Create a paper application
      visit new_admin_paper_application_path

      # Select applicant type first to make form fields visible
      choose 'An Adult (applying for themselves)'

      # Fill in constituent info
      within '#self-info-section' do
        fill_in 'First Name', with: 'John'
        fill_in 'Last Name', with: 'Paper'
        fill_in 'Email', with: 'john.paper@example.com'
        fill_in 'Phone', with: '555-987-6543'
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
      within('fieldset', text: 'Medical Provider Information') do
        fill_in 'Name', with: 'Dr. Jones'
        fill_in 'Email', with: 'jones@example.com'
        fill_in 'Phone', with: '555-333-4444'
      end

      # Upload proof documents
      attach_file 'income_proof', Rails.root.join('test/fixtures/files/income_proof.pdf')
      attach_file 'residency_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')

      # Submit the form
      click_button 'Submit Paper Application'

      # Verify application was created
      assert_text 'Paper application successfully submitted'

      # Verify the audit log shows the application creation
      within '#audit-logs' do
        assert_text 'Application Created (Paper)'
        assert_text 'Application created via Paper method'
      end
    end
  end
end
