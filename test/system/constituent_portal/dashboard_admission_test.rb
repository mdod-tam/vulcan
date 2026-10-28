# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module ConstituentPortal
  class DashboardAdmissionTest < ApplicationSystemTestCase
    include SystemTestEvidence

    test 'approved dashboard admission stays blocked while its service duration remains visible' do
      user = create(:constituent, :with_disabilities)
      create(:application, :approved, user: user, application_date: 1.year.ago.to_date)
      sign_in(user)

      visit constituent_portal_dashboard_path

      within '[data-testid="application-admission-card"]' do
        assert_text 'Application status'
        assert_text 'You already have an active or pending application.'
        assert_text "24 months remain in this application's service window."
        assert_no_text 'You are eligible to submit a new application.'
      end
      take_evidence_screenshot('checkpoint2-dashboard-approved-blocking', full: true, html: true)
    end
  end
end
