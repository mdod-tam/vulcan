# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class IncomeThresholdTest < ApplicationSystemTestCase
    include OnlineApplicationTestHelpers

    setup do
      @constituent = create(:constituent,
                            first_name: 'Sophia',
                            last_name: 'Martinez',
                            email: 'sophia.martinez@example.com',
                            phone: '4105551234',
                            physical_address_1: '789 Elm Avenue',
                            city: 'Frederick',
                            state: 'MD',
                            zip_code: '21702')
      system_test_sign_in(@constituent)

      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_2_person').update(value: 21_150)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)
    end

    test 'constituent cannot submit application when income exceeds threshold' do
      visit new_constituent_portal_application_path

      check 'I certify that I am a resident of Maryland'

      fill_in 'Household Size', with: '2'
      fill_in 'Annual Income', with: '100000'

      # Leave the field to trigger blur validation. A body click could toggle a checkbox mid-page.
      find_field('Annual Income').send_keys(:tab)

      assert_selector '#income-threshold-warning:not(.hidden)', visible: true

      assert_selector "input[name='submit_application'][disabled]"

      find("input[name='submit_application']").click

      assert_current_path new_constituent_portal_application_path
    end

    test 'constituent can submit application when income is within threshold' do
      visit new_constituent_portal_application_path

      check 'I certify that I am a resident of Maryland'
      check 'I certify that I have a disability that affects my ability to access telecommunications services'
      check 'Hearing'

      fill_in 'Household Size', with: '2'
      fill_in 'Annual Income', with: '50000'

      # Leave the field to trigger blur validation. A body click could toggle a checkbox mid-page.
      find_field('Annual Income').send_keys(:tab)

      assert_selector '#income-threshold-warning[hidden]', visible: :all

      # Income within the threshold does not complete the required proof and consent controls.
      assert_selector "input[name='submit_application'][disabled]"

      attach_required_documents
      within('#medical-provider-fields') do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '555-123-4567'
        fill_in 'Email', with: 'dr.smith@example.com'
        check 'I authorize the release and sharing of my disability-related information as described above'
      end
      accept_submit_confirmations
      wait_for_fpl_data_to_load(timeout: 15)

      assert_no_selector "input[name='submit_application'][disabled]"
    end

    test 'warning appears and disappears dynamically as income changes' do
      visit new_constituent_portal_application_path

      fill_in 'Household Size', with: '2'

      fill_in 'Annual Income', with: '100000'
      find_field('Annual Income').send_keys(:tab)

      assert_selector '#income-threshold-warning:not(.hidden)', visible: true

      fill_in 'Annual Income', with: '50000'
      find_field('Annual Income').send_keys(:tab)

      assert_selector '#income-threshold-warning[hidden]', visible: :all

      fill_in 'Annual Income', with: '100000'
      find_field('Annual Income').send_keys(:tab)

      assert_selector '#income-threshold-warning:not(.hidden)', visible: true
    end
  end
end
