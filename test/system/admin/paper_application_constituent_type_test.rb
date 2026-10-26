# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class PaperApplicationConstituentTypeTest < ApplicationSystemTestCase
    test 'creates paper application with correct constituent type' do
      skip 'Skipping until paper application form validations are stabilized'

      admin = create(:admin, verified: true)

      system_test_sign_in(admin)

      visit admin_applications_path
      assert_selector 'h1', text: 'Admin Dashboard'

      visit new_admin_paper_application_path

      assert_selector 'label', text: 'An Adult (applying for themselves)'
      choose 'applicant_is_adult'

      assert_selector '#self-info-section', visible: true

      fill_in 'constituent_first_name', with: 'Test'
      fill_in 'constituent_last_name', with: 'User'
      fill_in 'constituent_date_of_birth', with: 30.years.ago.strftime('%Y-%m-%d')
      fill_in 'constituent_email', with: "test-system-#{Time.now.to_i}@example.com"
      fill_in 'constituent_phone', with: '2025559876'
      fill_in 'constituent_physical_address_1', with: '123 Test St'
      fill_in 'constituent_city', with: 'Baltimore'
      fill_in 'constituent_state', with: 'MD'
      fill_in 'constituent_zip_code', with: '21201'
      check 'applicant_attributes_cognition_disability'

      fill_in 'application_household_size', with: '2'
      fill_in 'application_annual_income', with: '15000'
      check 'application_maryland_resident'
      check 'applicant_attributes_self_certify_disability'

      fill_in 'application_medical_provider_name', with: 'Dr. Smith'
      fill_in 'application_medical_provider_phone', with: '2025551212'
      fill_in 'application_medical_provider_email', with: 'drsmith@example.com'

      attach_pdf_proof('income')
      choose 'accept_income_proof'

      attach_pdf_proof('residency')
      choose 'accept_residency_proof'

      before_count = Application.count
      test_email = find_field('constituent_email').value

      click_button 'Submit Paper Application'

      assert_match %r{/admin/applications/\d+}, current_path,
                   'Should be redirected to the new application show page'

      assert_equal before_count + 1, Application.count,
                   'Application count should have increased by 1'

      newest_app = Application.order(created_at: :desc).first
      assert_equal test_email, newest_app.user.email,
                   'Application should be created for the test constituent'
      assert_equal 'Users::Constituent', newest_app.user.type,
                   'User should be of type Constituent'
    end

    private

    def attach_pdf_proof(type)
      fixture_path = Rails.root.join('test/fixtures/files', "#{type}_proof.pdf")
      fixture_path = Rails.root.join('test/fixtures/files/blank.pdf') unless File.exist?(fixture_path)
      raise "Missing test fixture file: #{fixture_path}" unless File.exist?(fixture_path)

      attach_cleared_document "#{type}_proof", fixture_path
    end
  end
end
