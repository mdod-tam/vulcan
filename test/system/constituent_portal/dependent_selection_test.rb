# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class DependentSelectionTest < ApplicationSystemTestCase
    setup do
      # Create a guardian (current user) with multiple dependents
      # Using unique phone numbers that match the 10-digit US format
      timestamp = Time.current.to_i

      # Create actual unique users since the test helper doesn't support attributes
      @guardian = Users::Constituent.create!(
        email: "guardian.test.#{timestamp}@example.com",
        phone: "555123#{timestamp.to_s[-4..]}",
        first_name: 'Guardian',
        last_name: 'User',
        password: 'password123',
        password_confirmation: 'password123'
      )

      # Create two dependents with different names
      @dependent1 = Users::Constituent.create!(
        first_name: 'First',
        last_name: 'Dependent',
        email: "dep1.#{timestamp}@example.com",
        phone: "555234#{timestamp.to_s[-4..]}",
        password: 'password123',
        password_confirmation: 'password123'
      )

      @dependent2 = Users::Constituent.create!(
        first_name: 'Second',
        last_name: 'Dependent',
        email: "dep2.#{timestamp}@example.com",
        phone: "555345#{timestamp.to_s[-4..]}",
        password: 'password123',
        password_confirmation: 'password123'
      )

      # Create guardian relationships using the actual model (avoid duplicates)
      GuardianRelationship.find_or_create_by!(
        guardian_id: @guardian.id,
        dependent_id: @dependent1.id
      ) do |relationship|
        relationship.relationship_type = 'Parent'
      end

      GuardianRelationship.find_or_create_by!(
        guardian_id: @guardian.id,
        dependent_id: @dependent2.id
      ) do |relationship|
        relationship.relationship_type = 'Legal Guardian'
      end

      # Sign in as the guardian
      system_test_sign_in(@guardian)

      # After sign-in, we need to explicitly visit the dashboard
      visit constituent_portal_dashboard_path
      wait_for_turbo

      # Verify we're on the dashboard page
      assert_text 'My Dashboard', wait: 10
    end

    test 'clicking Start Application from dashboard shows correct dependent name in title' do
      # Visit the dashboard page
      visit constituent_portal_dashboard_path
      wait_for_turbo

      # Ensure the dependents section is visible
      assert_selector 'h4', text: 'My Dependents', wait: 5, visible: :all

      # Find the row for the first dependent
      within('li', text: @dependent1.full_name, visible: :all) do
        # Click the "Start Application" button for the first dependent
        click_on 'Start Application', visible: :all
      end

      # Wait for the application form to load
      wait_for_turbo

      # Verify the page title includes the dependent's name
      assert_selector 'h1#form-title', text: "New Application for #{@dependent1.full_name}", wait: 5, visible: :all
    end

    test 'toggling between Myself and A dependent I manage radio buttons updates title correctly' do
      skip 'Applicant type is determined by URL params, not radio buttons'

      # Visit the new application page
      visit new_constituent_portal_application_path
      wait_for_turbo

      # By default, "Myself" should be selected and title should be "New Application"
      assert_checked_field 'Myself'
      assert_selector 'h1#form-title', text: 'New Application', wait: 5

      # Select "A dependent I manage" radio button
      choose 'A dependent I manage'

      # Dependent selection should become visible - use new turbo-frame ID
      assert_selector '#dependent-selection-fields', visible: true, wait: 5

      # Select the first dependent from the dropdown
      select @dependent1.full_name, from: 'Select Dependent'

      # Wait for JavaScript to execute and update the title
      assert_selector 'h1#form-title', text: "New Application for #{@dependent1.full_name}", wait: 5

      # Switch back to "Myself"
      choose 'Myself'

      # Wait for JavaScript to complete
      wait_for_turbo

      # Title should change back to "New Application"
      assert_selector 'h1#form-title', text: 'New Application', wait: 5

      # Dependent selection should be hidden (hidden class applied)
      element = find_by_id('dependent-selection-fields', visible: :all)
      assert element[:class].to_s.include?('hidden')
    end

    test 'selecting different dependents from dropdown updates title correctly' do
      skip 'Dependent selection is done via dashboard, not form dropdown'

      # Use the dashboard approach that works - visit with proper parameters
      visit new_constituent_portal_application_path(user_id: @dependent1.id, for_self: false)
      wait_for_turbo

      # Verify we're on the dependent application page with correct title
      assert_selector 'h1#form-title', text: "New Application for #{@dependent1.full_name}", wait: 5

      # Verify the dependent radio button is selected
      assert_checked_field 'A dependent I manage'

      # Verify the dependent dropdown is visible and has the correct selection
      assert_selector '#dependent_select_frame', visible: true

      # Change to the second dependent by selecting from dropdown
      select @dependent2.full_name, from: 'Select Dependent'

      # Verify title updates to second dependent's name
      assert_selector 'h1#form-title', text: "New Application for #{@dependent2.full_name}", wait: 5
    end

    test 'handles application form with url parameter for dependent' do
      # Visit the application page with user_id parameter for dependent1
      visit new_constituent_portal_application_path(user_id: @dependent1.id, for_self: false)
      wait_for_turbo

      # Verify title includes the dependent's name
      assert_selector 'h1#form-title', text: "New Application for #{@dependent1.full_name}", wait: 5
    end

    test 'handles application form with for_self=false parameter' do
      skip 'for_self=false requires user_id param to specify which dependent'

      # Visit the new application page with for_self=false parameter
      visit new_constituent_portal_application_path(for_self: false)
      wait_for_turbo

      # Verify "A dependent I manage" is selected automatically
      assert_checked_field 'A dependent I manage'

      # Verify the dependent dropdown is visible - use new turbo-frame ID
      assert_selector '#dependent_select_frame', visible: true, wait: 5

      # Verify the dropdown exists but no dependent is selected yet
      within('#dependent_select_frame') do
        assert_selector 'select[data-dependent-selector-target="dependentSelect"]'
        assert_no_selector "option[selected][value='#{@dependent1.id}']"
        assert_no_selector "option[selected][value='#{@dependent2.id}']"
      end

      # Title should still be "New Application" until a dependent is selected
      assert_selector 'h1#form-title', text: 'New Application', wait: 5

      # Select a dependent
      select @dependent2.full_name, from: 'Select Dependent'

      # Title should update to include the dependent's name
      assert_selector 'h1#form-title', text: "New Application for #{@dependent2.full_name}", wait: 5
    end
  end
end
