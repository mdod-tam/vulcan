# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  class LifecycleMaintenanceTest < ApplicationSystemTestCase
    include SystemTestEvidence

    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      Current.user = @admin
    end

    test 'application edit retains an invalid draft then refreshes the user summary and returns focus to details' do
      user = create(:constituent, :with_disabilities)
      application = create(:application, :in_progress, user: user)
      application.update_column(:updated_at, 2.days.ago)
      system_test_sign_in(@admin)
      visit admin_user_path(user)
      assert_selector '#user-application-summary', text: "Last updated: #{application.updated_at.strftime('%b %d, %Y')}"
      find("#user-application-summary button[data-application-id='#{application.id}']").click
      assert_selector '#application-modal[open]'
      within('#application-modal') { find_by_id('modal-edit-button').click }
      assert_selector '#application-edit-modal[open]'
      within('#application-edit-modal') do
        fill_in 'application_certifying_professional_name', with: ''
        click_button 'Update Application'
        assert_selector '#error_explanation'
        assert_field 'application_certifying_professional_name', with: ''
      end
      take_evidence_screenshot('application-modal-invalid-draft', html: true, full: true)
      within('#application-edit-modal') do
        fill_in 'application_certifying_professional_name', with: 'Dr. Local Refresh'
        click_button 'Update Application'
      end
      assert_no_selector '#application-edit-modal[open]'
      assert_selector '#application-modal[open]'
      assert_selector '#application-modal-content', text: 'Dr. Local Refresh'
      assert_equal 'modal-edit-button', page.evaluate_script('document.activeElement.id')
      take_evidence_screenshot('application-modal-updated-details', html: true, full: true)
      provider = find('#application-modal-content p', text: 'Dr. Local Refresh', exact_text: true)
      page.execute_script('arguments[0].scrollIntoView({ block: "center" })', provider)
      take_evidence_screenshot('application-modal-updated-provider', html: true, selector: '#application-modal')
      within('#application-modal') { click_button 'Close modal' }
      assert_selector '#user-application-summary', text: "Last updated: #{Time.current.strftime('%b %d, %Y')}"
      assert_equal 'Dr. Local Refresh', application.reload.certifying_professional_name
      take_evidence_screenshot('application-user-summary-refreshed', full: true, html: true)
    end

    test 'evaluator shortcuts keep the document and focus the fragment heading' do
      system_test_sign_in(@admin)
      visit evaluators_dashboard_path
      page.execute_script('window.lifecycleDocumentIdentity = "same-document"')
      {
        'View requested' => 'needs-scheduling-heading',
        'My scheduled' => 'my-upcoming-evaluations-table-heading',
        'View completed' => 'recent-completed-heading'
      }.each do |label, heading|
        find_link(label).send_keys(:enter)
        assert_selector "h2##{heading}:focus"
        assert_equal "##{heading}", page.evaluate_script('location.hash')
        assert_equal heading, page.evaluate_script('document.activeElement.id')
        assert_equal 'same-document', page.evaluate_script('window.lifecycleDocumentIdentity')
      end
      page.go_back
      assert_current_path(/#my-upcoming-evaluations-table-heading\z/, url: true)
      assert_equal 'same-document', page.evaluate_script('window.lifecycleDocumentIdentity')
      take_evidence_screenshot('evaluator-native-anchor-focus', html: true, full: true)
    end
  end
end
