# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class DisabilityValidationTest < ApplicationSystemTestCase
    include OnlineApplicationTestHelpers

    setup do
      setup_fpl_policies
      @constituent = create(:constituent)

      system_test_sign_in(@constituent)
      visit new_constituent_portal_application_path
      wait_for_turbo
    end

    test 'a server-refused submission preserves the entered application and disability fields' do
      fill_in_online_application_fields(
        household_size: 3, annual_income: 60_000, disabilities: %w[Hearing Vision],
        provider: { name: '', phone: '2025551234', email: 'drsmith@example.com' }
      )
      attach_required_documents
      accept_submit_confirmations
      wait_for_fpl_data_to_load(timeout: 15)
      assert_no_selector '#error-summary'
      assert_selector 'input[name="submit_application"]:not([disabled])', wait: 15
      page.driver.clear_network_traffic
      assert_no_difference -> { Application.where(user: @constituent).where.not(status: :draft).count } do
        click_button 'Submit Application'
        assert_selector '#error-summary[role="alert"]', text: 'Certifying professional information is required for submission.'
      end
      submission = page.driver.network_traffic.find do |exchange|
        exchange.request&.method == 'POST' && URI(exchange.request.url).path == constituent_portal_applications_path
      end
      assert_not_nil submission, 'The enabled final-submit control must send the application POST'
      assert_equal 422, submission.response&.status

      assert_checked_field 'I certify that I am a resident of Maryland'
      assert_field 'Household Size', with: '3', disabled: false
      assert_equal 60_000, find_field('Annual Income', disabled: false).value.to_f
      assert_checked_field 'I certify that I have a disability that affects my ability to access telecommunications services'
      assert_checked_field 'Hearing'
      assert_checked_field 'Vision'
      within '#certifying-professional-fields' do
        assert_field 'Name', with: '', disabled: false
        assert_field 'Phone', with: '2025551234', disabled: false
        assert_field 'Email', with: 'drsmith@example.com', disabled: false
      end
      take_screenshot('application-provider-refusal-preserved', full: true, html: true)

      fill_in 'Household Size', with: '4'
      fill_in 'Annual Income', with: '55000'
      within '#certifying-professional-fields' do
        fill_in 'Phone', with: '2025559876'
        fill_in 'Email', with: 'corrected@example.com'
        fill_in 'Name', with: 'Dr. Corrected Provider'
      end
      find('h1').click

      assert_field 'Household Size', with: '4'
      assert_equal 55_000, find_field('Annual Income').value.to_f
      within '#certifying-professional-fields' do
        assert_field 'Phone', with: '2025559876'
        assert_field 'Email', with: 'corrected@example.com'
        assert_field 'Name', with: 'Dr. Corrected Provider'
      end
    end
  end
end
