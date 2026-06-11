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

    test 'keeps submit disabled without selecting disabilities' do
      # Fill in required fields
      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 50_000
      check 'I certify that I have a disability that affects my ability to access telecommunications services'
      clear_disability_type_checkboxes

      # Fill medical provider info
      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      attach_required_documents
      accept_submit_confirmations

      # Wait for FPL thresholds to load
      wait_for_fpl_data_to_load(timeout: 15)

      assert_selector 'input[name="submit_application"]:disabled', wait: 15
      assert_selector '#portal-submit-gate-status',
                      text: 'Complete all required confirmations before submitting.',
                      visible: :all
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
      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      attach_required_documents
      accept_submit_confirmations

      # Wait for FPL thresholds to load and enable submit via income validation
      wait_for_fpl_data_to_load(timeout: 15)
      assert_no_selector 'input[name="submit_application"]:disabled', wait: 15
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
      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      attach_required_documents
      accept_submit_confirmations

      # Wait for FPL thresholds to load and enable submit via income validation
      wait_for_fpl_data_to_load(timeout: 15)
      assert_no_selector 'input[name="submit_application"]:disabled', wait: 15
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
      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Draft Doctor'
        fill_in 'Phone', with: '555-000-0000'
        fill_in 'Email', with: 'draft@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      # Upload required documents for draft
      attach_file 'Upload Residency Proof Document', @valid_image
      attach_file 'Upload Income Proof Document', @valid_pdf

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
      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Draft Doctor'
        fill_in 'Phone', with: '555-000-0000'
        fill_in 'Email', with: 'draft@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      # Upload required documents for draft
      attach_file 'Upload Residency Proof Document', @valid_image
      attach_file 'Upload Income Proof Document', @valid_pdf

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
      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      accept_submit_confirmations

      # Wait for FPL thresholds to load and enable submit via income validation
      wait_for_fpl_data_to_load(timeout: 15)
      assert_no_selector 'input[name="submit_application"]:disabled', wait: 15
      click_button 'Submit Application'

      # Should be successful
      assert_success_message('Application submitted successfully')

      # Verify the disabilities were saved
      @constituent.reload
      assert @constituent.hearing_disability
      assert @constituent.cognition_disability
    end

    test 'preserves disability selections when provider info is incomplete' do
      # Fill in required fields
      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 50_000
      check 'I certify that I have a disability that affects my ability to access telecommunications services'

      # Select disabilities
      check 'Hearing'
      check 'Vision'

      attach_required_documents
      accept_submit_confirmations

      # Fill medical provider info but intentionally make it invalid to cause validation failure
      within '#medical-provider-fields' do
        # Leave name blank intentionally, but fill other required fields
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'test@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      # Wait for FPL thresholds to load, then submit with incomplete provider info.
      wait_for_fpl_data_to_load(timeout: 15)
      assert_no_selector 'input[name="submit_application"]:disabled', wait: 15
      click_button 'Submit Application'

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
      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      attach_required_documents
      accept_submit_confirmations

      # Wait for FPL thresholds to load and enable submit via income validation
      wait_for_fpl_data_to_load(timeout: 15)
      assert_no_selector 'input[name="submit_application"]:disabled', wait: 15
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

    private

    def attach_required_documents
      attach_file 'Upload Residency Proof Document', @valid_image
      attach_file 'Upload Income Proof Document', @valid_pdf
      attach_file 'Upload ID Proof Document', @valid_image
    end

    def accept_submit_confirmations
      find_by_id('terms_accepted').check
      find_by_id('information_verified').check
    end

    def clear_disability_type_checkboxes
      %w[Hearing Vision Speech Mobility Cognition].each do |label|
        uncheck label if page.has_checked_field?(label)
      end
    end
  end
end
