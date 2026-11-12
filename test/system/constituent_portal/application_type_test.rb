# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class ApplicationTypeTest < ApplicationSystemTestCase
    include OnlineApplicationTestHelpers

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

      fill_in_online_application_fields(
        household_size: 3, annual_income: 45_999,
        provider: { name: 'Dr. Test Provider', phone: '2025551234', email: 'test@example.com' },
        address: { physical_address_1: '123 Test St', city: 'Baltimore', state: 'Maryland', zip_code: '21201' }
      )
      save_online_application_draft

      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)
      application = Application.find(application_id)

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

      fill_in_online_application_fields(
        household_size: 3, annual_income: 45_999,
        provider: { name: 'Dr. Test Provider', phone: '2025551234', email: 'test@example.com' },
        address: { physical_address_1: '123 Test St', city: 'Baltimore', state: 'Maryland', zip_code: '21201' }
      )
      save_online_application_draft

      current_url =~ %r{/applications/(\d+)}
      application_id = ::Regexp.last_match(1)
      assert application_id.present?, "Failed to extract application ID from URL: #{current_url}"

      application = Application.find(application_id)

      assert application.self_certify_disability, 'self_certify_disability should be true'

      assert_selector 'dt', text: 'Self-Certified Disability'
      assert_selector 'dd', text: 'Yes'
    end
  end
end
