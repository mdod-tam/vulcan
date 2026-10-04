# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class ApplicationTypeTest < ApplicationSystemTestCase
    setup do
      @constituent = create(:constituent)
      system_test_sign_in(@constituent)

      visit constituent_portal_dashboard_path
      assert_current_path constituent_portal_dashboard_path
    end

    test 'application type is displayed correctly on show page' do
      # With no user_id param, the form is a self-application.
      visit new_constituent_portal_application_path
      wait_for_turbo

      # set('') before each value prevents concatenation with prefilled values.
      check 'I certify that I am a resident of Maryland'
      safe_fill_household_and_income(3, 45_999)

      find('input[name*="physical_address_1"]').set('').set('123 Test St')
      find('input[name*="city"]').set('').set('Baltimore')
      select 'Maryland', from: 'State'
      find('input[name*="zip_code"]').set('').set('21201')

      check 'I certify that I have a disability that affects my ability to access telecommunications services'
      check 'Hearing'

      within '#medical-provider-fields' do
        find('input[name="application[medical_provider_attributes][name]"]').set('').set('Dr. Test Provider')
        find('input[name="application[medical_provider_attributes][phone]"]').set('').set('2025551234')
        find('input[name="application[medical_provider_attributes][email]"]').set('').set('test@example.com')
      end

      check 'I authorize the release and sharing of my disability-related information as described above'

      find('input[type="submit"][name="save_draft"]').click

      assert_application_saved_as_draft(wait: 10)

      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)
      application = Application.find(application_id)

      puts "DEBUG: Application type: #{application.application_type.inspect}"

      # The show page puts the label and the value in separate dt and dd elements.
      assert_selector 'dt', text: 'Application Type'
      assert_selector 'dd', text: application.application_type&.titleize || 'Not specified'

      application.update(application_type: 'new')

      visit current_path

      assert_selector 'dt', text: 'Application Type'
      assert_selector 'dd', text: 'New'

      application.update(application_type: 'renewal')

      visit current_path

      assert_selector 'dt', text: 'Application Type'
      assert_selector 'dd', text: 'Renewal'
    end

    test 'self_certify_disability is set correctly' do
      visit new_constituent_portal_application_path
      wait_for_turbo

      check 'I certify that I am a resident of Maryland'
      safe_fill_household_and_income(3, 45_999)

      find('input[name*="physical_address_1"]').set('').set('123 Test St')
      find('input[name*="city"]').set('').set('Baltimore')
      select 'Maryland', from: 'State'
      find('input[name*="zip_code"]').set('').set('21201')

      within 'section', text: 'Disability Information' do
        check_box = find('label', text: /I certify that I have a disability/).find(:xpath, '..//input[@type="checkbox"]')
        check_box.check

        find('label', text: 'Hearing').find(:xpath, '..//input[@type="checkbox"]').check
      end

      within '#medical-provider-fields' do
        find('input[name="application[medical_provider_attributes][name]"]').set('').set('Dr. Test Provider')
        find('input[name="application[medical_provider_attributes][phone]"]').set('').set('2025551234')
        find('input[name="application[medical_provider_attributes][email]"]').set('').set('test@example.com')
      end

      check 'I authorize the release and sharing of my disability-related information as described above'

      find('input[type="submit"][name="save_draft"]').click

      assert_application_saved_as_draft(wait: 10)

      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)
      assert application_id.present?, "Failed to extract application ID from URL: #{current_url}"

      application = Application.find(application_id)

      puts "DEBUG: self_certify_disability: #{application.self_certify_disability.inspect}"
      puts "DEBUG: hearing_disability: #{application.user.hearing_disability.inspect}"

      assert application.self_certify_disability, 'self_certify_disability should be true'

      assert_selector 'dt', text: 'Self-Certified Disability'
      assert_selector 'dd', text: 'Yes'
    end
  end
end
