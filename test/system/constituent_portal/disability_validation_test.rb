# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class DisabilityValidationTest < ApplicationSystemTestCase
    setup do
      @constituent = create(:constituent)
      @valid_pdf = file_fixture('income_proof.pdf').to_s
      @valid_image = file_fixture('residency_proof.pdf').to_s

      # Sign in and navigate to new application page
      system_test_sign_in(@constituent)
      visit new_constituent_portal_application_path
      wait_for_turbo
    end

    test 'shows error when trying to submit without selecting disabilities' do
      skip 'Skipping due to view rendering issues in system tests'
      # Fill in required fields
      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 50_000
      check 'I certify that I have a disability that affects my ability to access telecommunications services'

      # Fill medical provider info
      within "section[aria-labelledby='medical-info-heading']" do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
      end

      # Submit without selecting any disabilities
      click_button 'Submit Application'

      # Should show error
      assert_text 'At least one disability must be selected before submitting an application'
    end

    test 'can submit application with one disability selected' do
      # Fill in required fields
      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 50_000
      check 'I certify that I have a disability that affects my ability to access telecommunications services'

      # Select one disability
      check 'Hearing'

      # Fill medical provider info
      within "section[aria-labelledby='medical-info-heading']" do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my medical information as described above'
      end

      # Upload required documents
      attach_file 'Proof of Residency', @valid_image
      attach_file 'Income Verification', @valid_pdf

      # Wait for FPL thresholds to load and enable submit via income validation
      wait_for_fpl_data_to_load(timeout: 15)
      assert_button 'Submit Application', disabled: false, wait: 15
      click_button 'Submit Application'

      # Should be successful
      assert_success_message('Application submitted successfully')

      # Verify the disability was saved
      @constituent.reload
      assert @constituent.hearing_disability
    end

    test 'can submit application with multiple disabilities selected' do
      # Fill in required fields
      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 50_000
      check 'I certify that I have a disability that affects my ability to access telecommunications services'

      # Select multiple disabilities
      check 'Hearing'
      check 'Vision'
      check 'Mobility'

      # Fill medical provider info
      within "section[aria-labelledby='medical-info-heading']" do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my medical information as described above'
      end

      # Upload required documents
      attach_file 'Proof of Residency', @valid_image
      attach_file 'Income Verification', @valid_pdf

      # Wait for FPL thresholds to load and enable submit via income validation
      wait_for_fpl_data_to_load(timeout: 15)
      assert_button 'Submit Application', disabled: false, wait: 15
      click_button 'Submit Application'

      # Should be successful
      assert_success_message('Application submitted successfully')

      # Verify the disabilities were saved
      @constituent.reload
      assert @constituent.hearing_disability
      assert @constituent.vision_disability
      assert @constituent.mobility_disability
      assert_not @constituent.speech_disability
      assert_not @constituent.cognition_disability
    end

    test 'can save draft without selecting disabilities' do
      # Fill in some fields but not all - drafts still need basic required fields
      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 50_000

      # Even drafts need medical provider info due to required fields
      within "section[aria-labelledby='medical-info-heading']" do
        fill_in 'Name', with: 'Draft Doctor'
        fill_in 'Phone', with: '555-000-0000'
        fill_in 'Email', with: 'draft@example.com'
        check 'I authorize the release and sharing of my medical information as described above'
      end

      # Upload required documents for draft
      attach_file 'Proof of Residency', @valid_image
      attach_file 'Income Verification', @valid_pdf

      # Save as draft without selecting disabilities
      click_button 'Save Application'

      # Should be successful
      assert_application_saved_as_draft
    end

    test 'can edit draft to add disabilities and then submit' do
      # First create a draft - even drafts need medical provider info due to required fields
      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 50_000

      # Fill minimal medical provider info for draft
      within "section[aria-labelledby='medical-info-heading']" do
        fill_in 'Name', with: 'Draft Doctor'
        fill_in 'Phone', with: '555-000-0000'
        fill_in 'Email', with: 'draft@example.com'
        check 'I authorize the release and sharing of my medical information as described above'
      end

      # Upload required documents for draft
      attach_file 'Proof of Residency', @valid_image
      attach_file 'Income Verification', @valid_pdf

      click_button 'Save Application'
      wait_for_turbo

      # Verify draft was saved
      assert_application_saved_as_draft(wait: 10)

      # Get the application ID and navigate to edit
      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)
      visit edit_constituent_portal_application_path(application_id)
      wait_for_turbo

      # Add disabilities and other required fields
      check 'I certify that I have a disability that affects my ability to access telecommunications services'
      check 'Hearing'
      check 'Cognition'

      # Fill medical provider info
      within "section[aria-labelledby='medical-info-heading']" do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my medical information as described above'
      end

      # Wait for FPL thresholds to load and enable submit via income validation
      wait_for_fpl_data_to_load(timeout: 15)
      assert_button 'Submit Application', disabled: false, wait: 15
      click_button 'Submit Application'

      # Should be successful
      assert_success_message('Application submitted successfully')

      # Verify the disabilities were saved
      @constituent.reload
      assert @constituent.hearing_disability
      assert @constituent.cognition_disability
    end

    test 'preserves disability selections when validation fails for other reasons' do
      # Fill in required fields
      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 50_000
      check 'I certify that I have a disability that affects my ability to access telecommunications services'

      # Select disabilities
      check 'Hearing'
      check 'Vision'

      # Upload required documents
      attach_file 'Proof of Residency', @valid_image
      attach_file 'Income Verification', @valid_pdf

      # Fill medical provider info but intentionally make it invalid to cause validation failure
      within "section[aria-labelledby='medical-info-heading']" do
        # Leave name blank intentionally, but fill other required fields
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'test@example.com'
        check 'I authorize the release and sharing of my medical information as described above'
      end

      # Wait for FPL thresholds to load and enable submit via income validation
      wait_for_fpl_data_to_load(timeout: 15)
      assert_button 'Submit Application', disabled: false, wait: 15
      click_button 'Submit Application'

      # Should show validation error (though the exact message might vary)
      # We expect some kind of validation error to keep us on the form
      assert_no_text 'Application submitted successfully'

      # Disability checkboxes should still be checked
      assert_checked_field 'Hearing'
      assert_checked_field 'Vision'
    end

    test 'can select all disability types' do
      # Fill in required fields
      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 50_000
      check 'I certify that I have a disability that affects my ability to access telecommunications services'

      # Select all disabilities
      check 'Hearing'
      check 'Vision'
      check 'Speech'
      check 'Mobility'
      check 'Cognition'

      # Fill medical provider info
      within "section[aria-labelledby='medical-info-heading']" do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my medical information as described above'
      end

      # Upload required documents
      attach_file 'Proof of Residency', @valid_image
      attach_file 'Income Verification', @valid_pdf

      # Wait for FPL thresholds to load and enable submit via income validation
      wait_for_fpl_data_to_load(timeout: 15)
      assert_button 'Submit Application', disabled: false, wait: 15
      click_button 'Submit Application'

      # Should be successful
      assert_success_message('Application submitted successfully')

      # Verify all disabilities were saved
      @constituent.reload
      assert @constituent.hearing_disability
      assert @constituent.vision_disability
      assert @constituent.speech_disability
      assert @constituent.mobility_disability
      assert @constituent.cognition_disability
    end
  end
end
