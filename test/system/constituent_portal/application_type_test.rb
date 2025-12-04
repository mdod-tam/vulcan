# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class ApplicationTypeTest < ApplicationSystemTestCase
    setup do
      @constituent = create(:constituent)
      system_test_sign_in(@constituent) # Use enhanced sign-in for more reliable authentication

      # Make sure we're starting on the dashboard
      visit constituent_portal_dashboard_path
      assert_current_path constituent_portal_dashboard_path
    end

    test 'application type is displayed correctly on show page' do
      # Visit the new application page (self-application is the default)
      visit new_constituent_portal_application_path
      wait_for_turbo # Ensure the page is fully loaded before proceeding

      # Self-application is the default when visiting without user_id param.

      # Fill in required fields using our safe filling methods to prevent concatenation
      check 'I certify that I am a resident of Maryland'
      safe_fill_household_and_income(3, 45_999)

      # Fill in address information
      find('input[name*="physical_address_1"]').set('').set('123 Test St')
      find('input[name*="city"]').set('').set('Baltimore')
      select 'Maryland', from: 'State'
      find('input[name*="zip_code"]').set('').set('21201')

      # Fill in disability information
      check 'I certify that I have a disability that affects my ability to access telecommunications services'
      check 'Hearing'

      # Fill in medical provider info using correct nested attribute field names
      within "section[aria-labelledby='medical-info-heading']" do
        find('input[name="application[medical_provider_attributes][name]"]').set('').set('Dr. Test Provider')
        find('input[name="application[medical_provider_attributes][phone]"]').set('').set('2025551234')
        find('input[name="application[medical_provider_attributes][email]"]').set('').set('test@example.com')
      end

      # Check the medical authorization checkbox
      check 'I authorize the release and sharing of my medical information as described above'

      # Save the application using more specific button targeting
      find('input[type="submit"][name="save_draft"]').click

      # Verify we're redirected to the show page with proper wait time
      assert_application_saved_as_draft(wait: 10)

      # Get the application ID from the URL
      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)
      application = Application.find(application_id)

      # Debug the application type
      puts "DEBUG: Application type: #{application.application_type.inspect}"

      # Verify the application type is displayed correctly
      # The view uses definition lists so label and value are separate
      assert_selector 'dt', text: 'Application Type'
      assert_selector 'dd', text: application.application_type&.titleize || 'Not specified'

      # Update the application type directly in the database
      application.update(application_type: 'new')

      # Refresh the page
      visit current_path

      # Verify the updated application type is displayed
      assert_selector 'dt', text: 'Application Type'
      assert_selector 'dd', text: 'New'

      # Update the application type to renewal
      application.update(application_type: 'renewal')

      # Refresh the page
      visit current_path

      # Verify the updated application type is displayed
      assert_selector 'dt', text: 'Application Type'
      assert_selector 'dd', text: 'Renewal'
    end

    test 'self_certify_disability is set correctly' do
      # Visit the new application page (self-application is the default)
      visit new_constituent_portal_application_path
      wait_for_turbo # Ensure the page is fully loaded

      # Self-application is the default when visiting without user_id param.
      # Fill in required fields using safe methods to prevent concatenation
      check 'I certify that I am a resident of Maryland'
      safe_fill_household_and_income(3, 45_999)

      # Fill in address information with explicit field clearing
      find('input[name*="physical_address_1"]').set('').set('123 Test St')
      find('input[name*="city"]').set('').set('Baltimore')
      select 'Maryland', from: 'State'
      find('input[name*="zip_code"]').set('').set('21201')

      # Use a more reliable method to check the self-certify checkbox
      # Use find + check to ensure we're finding the right element
      within 'section', text: 'Disability Information' do
        # Find the checkbox by its associated label text
        check_box = find('label', text: /I certify that I have a disability/).find(:xpath, '..//input[@type="checkbox"]')
        check_box.check

        # Also check one of the specific disability checkboxes
        find('label', text: 'Hearing').find(:xpath, '..//input[@type="checkbox"]').check
      end

      # Fill in medical provider info using correct nested attribute field names
      within "section[aria-labelledby='medical-info-heading']" do
        find('input[name="application[medical_provider_attributes][name]"]').set('').set('Dr. Test Provider')
        find('input[name="application[medical_provider_attributes][phone]"]').set('').set('2025551234')
        find('input[name="application[medical_provider_attributes][email]"]').set('').set('test@example.com')
      end

      # Check the medical authorization checkbox
      check 'I authorize the release and sharing of my medical information as described above'

      # Save the application with explicit button identification
      find('input[type="submit"][name="save_draft"]').click

      # Verify we're redirected to the show page with longer wait time
      assert_application_saved_as_draft(wait: 10)

      # Get the application ID from the URL
      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)
      # Make sure we have a valid application ID
      assert application_id.present?, "Failed to extract application ID from URL: #{current_url}"

      application = Application.find(application_id)

      # Debug the self_certify_disability field
      puts "DEBUG: self_certify_disability: #{application.self_certify_disability.inspect}"
      puts "DEBUG: hearing_disability: #{application.user.hearing_disability.inspect}"

      # Verify the self_certify_disability field is set correctly
      assert application.self_certify_disability, 'self_certify_disability should be true'

      # Verify the self_certify_disability is displayed correctly
      assert_selector 'dt', text: 'Self-Certified Disability'
      assert_selector 'dd', text: 'Yes'
    end
  end
end
