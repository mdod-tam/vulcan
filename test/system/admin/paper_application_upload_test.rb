# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'

module Admin
  # End to end through the browser: a complete paper application, including the optional fax and
  # alternate contact, is created with every value staff entered and its uploaded documents.
  class PaperApplicationUploadTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper

    setup do
      @admin = create(:admin)
      setup_fpl_policies
      system_test_sign_in(@admin)
    end

    test 'a complete paper application with an alternate contact is created as entered' do
      visit new_admin_paper_application_path
      click_button 'Create New Applicant'
      phone = "202555#{format('%04d', SecureRandom.random_number(10_000))}"
      fill_in_applicant_information(first_name: 'Complete', last_name: 'Paper', phone: phone)
      attach_and_accept_proofs
      fill_in_application_details(household_size: 2, annual_income: 20_000)
      fill_in_disability_information
      fill_in_medical_provider_information(name: 'Dr. Jane Smith', email: 'dr.smith@example.com')
      fill_in 'application[medical_provider_fax]', with: '555-987-6544'
      fill_in 'application[alternate_contact_name]', with: 'Jane Doe'
      select 'Neighbor', from: 'application[alternate_contact_relationship_type]'
      fill_in 'application[alternate_contact_phone]', with: '555-123-4567'
      fill_in 'application[alternate_contact_email]', with: 'jane.doe@example.com'
      complete_paper_application_attestations

      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: /Application #\d+ Details/, wait: 20
      end
      assert_success_message('Paper application successfully submitted.')

      application = Application.order(:id).last
      assert_equal %w[Complete Paper], [application.user.first_name, application.user.last_name]
      assert_equal [2, 20_000], [application.household_size, application.annual_income.to_i]
      assert_equal ['Dr. Jane Smith', 'dr.smith@example.com', '555-987-6544'],
                   [application.medical_provider_name, application.medical_provider_email, application.medical_provider_fax]
      assert_equal ['Jane Doe', 'neighbor', '555-123-4567', 'jane.doe@example.com'],
                   [application.alternate_contact_name, application.alternate_contact_relationship_type,
                    application.alternate_contact_phone, application.alternate_contact_email]
      %i[income_proof residency_proof id_proof medical_certification].each do |document|
        assert application.public_send(document).attached?, "#{document} should be attached"
      end
    end
  end
end
