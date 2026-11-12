# frozen_string_literal: true

require 'application_system_test_case'

module ConstituentPortal
  class ApplicationShowTest < ApplicationSystemTestCase
    include OnlineApplicationTestHelpers

    test 'draft details show entered fields and subsequent edits without another intake' do
      constituent = create(:constituent)
      system_test_sign_in(constituent)
      visit new_constituent_portal_application_path
      fill_in_online_application_fields(
        household_size: 3, annual_income: 45_999, disabilities: %w[Hearing Vision],
        provider: { name: 'Benjamin Rush', phone: '2022222323', email: 'thunderbolts@rush.med' }
      )
      attach_online_application_documents(:residency_proof, :income_proof)
      save_online_application_draft
      application = constituent.applications.sole
      assert_current_path constituent_portal_application_path(application, format: :html)

      assert_selector '[aria-labelledby="details-heading"]', text: 'Draft'
      assert_text 'Household Size'
      assert_text '3'
      assert_text 'Annual Income'
      assert_text '$45,999.00'
      assert_text 'Application Type'
      assert_text application.application_type&.titleize || 'Not specified'
      assert_no_text 'Guardian Application:'
      assert_no_text 'Guardian Relationship:'
      assert_selector '[aria-labelledby="disability-heading"]', text: 'Self-Certified Disability'
      assert_selector '[aria-labelledby="disability-heading"]', text: 'Yes'
      assert_selector '[aria-labelledby="disability-heading"]', text: 'Disability Types'
      assert_selector '[aria-labelledby="disability-heading"]', text: 'Hearing, Vision'
      assert_text 'Name'
      assert_text 'Benjamin Rush'
      assert_text 'Phone'
      assert_text '2022222323'
      assert_text 'Email'
      assert_text 'thunderbolts@rush.med'
      assert_text 'Filename:'
      assert_text 'residency_proof.pdf'
      assert_text 'income_proof.pdf'

      visit edit_constituent_portal_application_path(application)
      fill_in_online_application_fields(
        household_size: 4, annual_income: 55_000, disabilities: %w[Hearing Vision Mobility],
        provider: { name: 'Dr. Benjamin Franklin', phone: '2025559876', email: 'bfranklin@example.com' }
      )
      save_online_application_draft
      assert_current_path constituent_portal_application_path(application, format: :html)
      assert_text '4'
      assert_text '$55,000.00'
      assert_selector '[aria-labelledby="disability-heading"]', text: 'Hearing, Vision, Mobility'
      assert_text 'Dr. Benjamin Franklin'
      assert_text '2025559876'
      assert_text 'bfranklin@example.com'

      visit edit_constituent_portal_application_path(application)
      uncheck 'Vision'
      uncheck 'Mobility'
      check 'Speech'
      check 'Cognition'
      save_online_application_draft
      within '[aria-labelledby="disability-heading"]' do
        assert_text 'Hearing, Speech, Cognition'
        assert_no_text 'Vision, Mobility'
      end
      assert_equal [application.id], constituent.applications.pluck(:id)
    end
  end
end
