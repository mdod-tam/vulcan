# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class IncomeThresholdTest < ApplicationSystemTestCase
    setup do
      @constituent = create(:constituent,
                            first_name: 'Sophia',
                            last_name: 'Martinez',
                            email: 'sophia.martinez@example.com',
                            phone: '4105551234',
                            physical_address_1: '789 Elm Avenue',
                            city: 'Frederick',
                            state: 'Maryland',
                            zip_code: '21702')
      system_test_sign_in(@constituent)

      # Set up FPL policies for testing
      Policy.find_or_create_by(key: 'fpl_1_person').update(value: 15_650)
      Policy.find_or_create_by(key: 'fpl_2_person').update(value: 21_150)
      Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)
    end

    test 'constituent cannot submit application when income exceeds threshold' do
      visit new_constituent_portal_application_path

      # Fill in required fields
      check 'I certify that I am a resident of Maryland'

      # Enter household size and income that exceeds threshold
      fill_in 'Household Size', with: '2'
      fill_in 'Annual Income', with: '100000' # 100k > 400% of 20k

      # Move focus to trigger validation
      find('body').click

      # Warning should be visible
      assert_selector '#income-threshold-warning:not(.hidden)', visible: true

      # Submit button should be disabled
      assert_selector "input[name='submit_application'][disabled]"

      # Try to submit the form by clicking the button (should not work)
      find("input[name='submit_application']").click

      # Should still be on the same page
      assert_current_path new_constituent_portal_application_path
    end

    test 'constituent can submit application when income is within threshold' do
      visit new_constituent_portal_application_path

      # Fill in required fields
      check 'I certify that I am a resident of Maryland'
      check 'I certify that I have a disability that affects my ability to access telecommunications services'
      check 'Hearing'

      # Enter household size and income within threshold
      fill_in 'Household Size', with: '2'
      fill_in 'Annual Income', with: '50000' # 50k < 400% of 20k

      # Move focus to trigger validation
      find('body').click

      # Warning should not be visible (check for hidden attribute or hidden class)
      assert_selector '#income-threshold-warning[hidden]', visible: :all

      # Submit button should be enabled
      assert_no_selector "input[name='submit_application'][disabled]"

      # Fill in remaining required fields
      attach_file 'Upload Residency Proof Document', Rails.root.join('test/fixtures/files/residency_proof.pdf')
      attach_file 'Upload Income Proof Document', Rails.root.join('test/fixtures/files/income_proof.pdf')

      # Fill in medical provider information
      within('section', text: 'Medical Professional Information') do
        fill_in 'Name', with: 'Dr. Smith'
        fill_in 'Phone', with: '5551234567'
        fill_in 'Email', with: 'dr.smith@example.com'
      end

      # Medical authorization (required)
      check 'I authorize the release and sharing of my medical information as described above'

      # Verify the form is ready for submission (submit button should be enabled)
      assert_no_selector "input[name='submit_application'][disabled]"
    end

    test 'warning appears and disappears dynamically as income changes' do
      visit new_constituent_portal_application_path

      # Fill in household size
      fill_in 'Household Size', with: '2'

      # Enter income that exceeds threshold
      fill_in 'Annual Income', with: '100000' # 100k > 400% of 20k
      find('body').click

      # Warning should be visible
      assert_selector '#income-threshold-warning:not(.hidden)', visible: true

      # Change income to be within threshold
      fill_in 'Annual Income', with: '50000' # 50k < 400% of 20k
      find('body').click

      # Warning should disappear (check for hidden attribute)
      assert_selector '#income-threshold-warning[hidden]', visible: :all

      # Change income back to exceed threshold
      fill_in 'Annual Income', with: '100000' # 100k > 400% of 20k
      find('body').click

      # Warning should reappear
      assert_selector '#income-threshold-warning:not(.hidden)', visible: true
    end
  end
end
