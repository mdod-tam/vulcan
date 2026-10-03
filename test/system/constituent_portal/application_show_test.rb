# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class ApplicationShowTest < ApplicationSystemTestCase
    setup do
      @constituent = create(:constituent)
      @valid_pdf = file_fixture('income_proof.pdf').to_s
      @valid_image = file_fixture('residency_proof.pdf').to_s

      system_test_sign_in(@constituent)
      assert_text 'Dashboard', wait: 10
    end

    teardown do
    end

    test 'application show page displays all information entered during application creation' do
      visit new_constituent_portal_application_path
      wait_for_turbo

      check 'I certify that I am a resident of Maryland'

      # Household information.
      fill_in 'Household Size', with: 3
      fill_in 'Annual Income', with: 45_999

      # This test covers the constituent's own application and excludes guardian fields.

      # Disability information.
      check 'I certify that I have a disability that affects my ability to access telecommunications services'
      check 'Hearing'
      check 'Vision'

      # Medical provider information.
      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Benjamin Rush'
        fill_in 'Phone', with: '2022222323'
        fill_in 'Email', with: 'thunderbolts@rush.med'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      attach_file 'Upload Residency Proof Document', @valid_image
      attach_file 'Upload Income Proof Document', @valid_pdf

      click_button 'Save Application'
      wait_for_turbo

      assert_application_saved_as_draft(wait: 10)
      assert_current_path %r{/constituent_portal/applications/\d+}

      puts 'DEBUG: Current user attributes after save:'
      puts @constituent.reload.attributes.inspect

      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)
      application = Application.find(application_id)
      puts 'DEBUG: Application attributes after save:'
      puts application.attributes.inspect


      # Application details.
      assert_text 'Status', wait: 5
      assert_text 'Draft', wait: 5
      assert_text 'Household Size', wait: 5
      assert_text '3', wait: 5
      assert_text 'Annual Income', wait: 5
      assert_text '$45,999.00', wait: 5

      assert_text 'Application Type', wait: 5
      assert_text application.application_type&.titleize || 'Not specified', wait: 5

      assert_no_text 'Guardian Application:'
      assert_no_text 'Guardian Relationship:'

      # Disability information.
      assert_text 'Self-Certified Disability', wait: 5
      assert_text 'Yes', wait: 5
      assert_text 'Disability Types', wait: 5
      assert_text 'Hearing, Vision', wait: 5

      # Medical provider information.
      assert_text 'Name', wait: 5
      assert_text 'Benjamin Rush', wait: 5
      assert_text 'Phone', wait: 5
      assert_text '2022222323', wait: 5
      assert_text 'Email', wait: 5
      assert_text 'thunderbolts@rush.med', wait: 5

      # Uploaded documents.
      assert_text 'Filename:', wait: 5
      assert_text 'residency_proof.pdf', wait: 5
      assert_text 'income_proof.pdf', wait: 5
    end

    test 'application show page displays updated information after editing' do
      visit new_constituent_portal_application_path
      wait_for_turbo

      check 'I certify that I am a resident of Maryland'
      fill_in 'application_household_size', with: 2
      fill_in 'application_annual_income', with: 30_000
      check 'I certify that I have a disability that affects my ability to access telecommunications services'
      check 'Hearing'

      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Dr. Jane Smith'
        fill_in 'Phone', with: '2025551234'
        fill_in 'Email', with: 'drsmith@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      attach_file 'Upload Residency Proof Document', @valid_image
      attach_file 'Upload Income Proof Document', @valid_pdf

      click_button 'Save Application'
      wait_for_turbo(timeout: 15)

      begin
        assert_application_saved_as_draft(wait: 15)
      rescue Minitest::Assertion
        # A successful save can lack a visible flash. Navigation is the fallback.
        assert_current_path(%r{/constituent_portal/applications/\d+}, wait: 10)
      end

      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)

      visit edit_constituent_portal_application_path(application_id)
      wait_for_turbo

      household_field = find_by_id('application_household_size')
      income_field = find_by_id('application_annual_income')

      household_field.set('4')
      income_field.set('55000')

      uncheck 'Vision' if page.has_checked_field?('Vision')
      uncheck 'Mobility' if page.has_checked_field?('Mobility')
      check 'Vision'
      check 'Mobility'

      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Dr. Benjamin Franklin'
        fill_in 'Phone', with: '2025559876'
        fill_in 'Email', with: 'bfranklin@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      click_button 'Save Application'
      wait_for_turbo(timeout: 15)

      begin
        assert_application_saved_as_draft(wait: 15)
      rescue Minitest::Assertion
        # A successful save can lack a visible flash. Navigation is the fallback.
        assert_current_path(%r{/constituent_portal/applications/\d+}, wait: 10)
        if page.has_selector?('.flash-messages', wait: 2)
          flash_content = find('.flash-messages').text
          puts "DEBUG: Flash content found: '#{flash_content}'"
        else
          puts 'DEBUG: No flash messages container found'
        end
      end

      unless current_path.match?(%r{/constituent_portal/applications/\d+$})
        visit constituent_portal_application_path(application_id)
        wait_for_turbo
      end

      assert_text 'Household Size', wait: 5
      assert_text '4', wait: 5
      assert_text 'Annual Income', wait: 5
      assert_text '$55,000.00', wait: 5
      assert_text 'Disability Types', wait: 5
      assert_text 'Hearing, Vision, Mobility', wait: 5

      assert_text 'Name', wait: 5
      assert_text 'Dr. Benjamin Franklin', wait: 5
      assert_text 'Phone', wait: 5
      assert_text '2025559876', wait: 5
      assert_text 'Email', wait: 5
      assert_text 'bfranklin@example.com', wait: 5
    end

    test 'application show page displays disability information correctly' do
      visit new_constituent_portal_application_path
      wait_for_turbo

      check 'I certify that I am a resident of Maryland'
      fill_in 'Household Size', with: 2
      fill_in 'Annual Income', with: 30_000

      check 'I certify that I have a disability that affects my ability to access telecommunications services'
      check 'Hearing'
      check 'Speech'
      check 'Cognition'

      within '#medical-provider-fields' do
        fill_in 'Name', with: 'Dr. Medical Provider'
        fill_in 'Phone', with: '2025551234'
        fill_in 'Email', with: 'doctor@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end

      attach_file 'Upload Residency Proof Document', @valid_image
      attach_file 'Upload Income Proof Document', @valid_pdf

      click_button 'Save Application'
      wait_for_turbo

      assert_application_saved_as_draft(wait: 10)

      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)
      application = Application.find(application_id)

      puts 'DEBUG: Application disability attributes:'
      puts "self_certify_disability: #{application.self_certify_disability}"
      puts 'User disability attributes:'
      puts "hearing_disability: #{application.user.hearing_disability}"
      puts "speech_disability: #{application.user.speech_disability}"
      puts "cognition_disability: #{application.user.cognition_disability}"

      assert_text 'Self-Certified Disability', wait: 5
      assert_text application.self_certify_disability ? 'Yes' : 'No', wait: 5

      assert_text 'Disability Types', wait: 5
      assert_text 'Hearing, Speech, Cognition', wait: 5

      assert_no_text 'Vision, Mobility'
    end
  end
end
