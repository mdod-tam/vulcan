# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module ConstituentPortal
  class LifecycleMaintenanceTest < ApplicationSystemTestCase
    include SystemTestEvidence

    test 'Spanish proof replacement copy fits a narrow dashboard and preserves authored notes' do
      ensure_system_audit_actor!
      user = create(:constituent, :with_disabilities, locale: 'es')
      application = create(:application, :in_progress, user: user, residency_proof_status: :rejected)
      review = create(:proof_review, :rejected, application: application, proof_type: 'residency', notes: 'Please replace this scan')
      system_test_sign_in(user)
      page.driver.browser.resize(width: 390, height: 844)
      visit constituent_portal_dashboard_path
      assert_text 'Comprobante de residencia'
      assert_text 'Motivo: Please replace this scan'
      assert_text I18n.l(review.created_at.to_date, format: :long, locale: :es)
      assert_link 'Subir nuevo comprobante de residencia'
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_evidence_screenshot('proof-card-spanish-narrow', html: true, full: true)
    end

    test 'ambiguous guardian ownership explains the refusal and preserves editable draft values' do
      ensure_system_audit_actor!
      user = create(:constituent, :with_disabilities)
      application = create(:application, :draft, user: user)
      create_list(:constituent, 2).each do |guardian|
        create(:guardian_relationship, guardian_user: guardian, dependent_user: user)
      end
      system_test_sign_in(user)
      visit edit_constituent_portal_application_path(application)
      fill_in 'application_household_size', with: 3
      fill_in 'application_annual_income', with: 20_000
      fill_in 'application_physical_address_1', with: '123 Retry Street'
      fill_in 'application_certifying_professional_attributes_name', with: 'Dr. Retry'
      fill_in 'application_certifying_professional_attributes_fax', with: '2025550199'
      fill_in 'application_alternate_contact_name', with: 'Retry Contact'
      check 'terms_accepted'
      find('input[name="save_draft"]').click
      assert_selector '#error-summary li', text: 'ask a guardian to apply from their own account', count: 1
      assert_field 'application_household_size', with: '3'
      assert_field 'application_annual_income', with: '20000'
      assert_field 'application_physical_address_1', with: '123 Retry Street'
      assert_field 'application_certifying_professional_attributes_name', with: 'Dr. Retry'
      assert_field 'application_certifying_professional_attributes_fax', with: '2025550199'
      assert_field 'application_alternate_contact_name', with: 'Retry Contact'
      assert_checked_field 'terms_accepted'
      find('input[name="save_draft"]').click
      assert_selector '#error-summary li', text: 'ask a guardian to apply from their own account', count: 1
      fill_in 'application_household_size', with: 4
      fill_in 'application_physical_address_1', with: '456 Corrected Street'
      fill_in 'application_certifying_professional_attributes_name', with: 'Dr. Corrected'
      fill_in 'application_certifying_professional_attributes_fax', with: ''
      fill_in 'application_alternate_contact_name', with: ''
      uncheck 'terms_accepted'
      take_evidence_screenshot('guardian-selection-refusal-editable', html: true, full: true)
      # A staff correction outside this browser removes the ambiguous relationship inventory.
      GuardianRelationship.where(dependent_id: user.id).destroy_all
      find('input[name="save_draft"]').click
      assert_current_path constituent_portal_application_path(application, format: :html)
      assert_equal 4, application.reload.household_size
      assert_equal '456 Corrected Street', user.reload.physical_address_1
      assert_equal 'Dr. Corrected', application.certifying_professional_name
      assert application.certifying_professional_fax.blank?
      assert application.alternate_contact_name.blank?
      assert_not application.terms_accepted?
    end

    test 'Spanish submit feedback remains localized through edits and autosave restoration' do
      ensure_system_audit_actor!
      user = create(:constituent, :with_disabilities, locale: 'es')
      application = create(:application, :completed, :draft, :with_all_proofs, user: user)
      system_test_sign_in(user)
      visit edit_constituent_portal_application_path(application)
      uncheck 'terms_accepted'
      status = find_by_id('portal-edit-submit-gate-status', visible: :all)
      assert_includes status.text(:all), I18n.t('applications.submit_gate.incomplete', locale: :es)
      assert_includes status.text(:all), I18n.t('applications.form_labels.terms_accepted', locale: :es)
      assert_not_includes status.text(:all), 'I have read and accept'
      fill_in 'application_household_size', with: 3
      fill_in 'application_annual_income', with: 20_000
      check 'application_disability_information_release_authorized'
      check 'information_verified'
      check 'terms_accepted'
      assert_selector '#portal-edit-submit-gate-status', text: I18n.t('applications.submit_gate.ready', locale: :es), visible: :all
      assert_selector 'input[name="submit_application"]:enabled'
      uncheck 'terms_accepted'
      assert_selector '#portal-edit-submit-gate-status', text: I18n.t('applications.submit_gate.incomplete', locale: :es), visible: :all
      take_evidence_screenshot('constituent-submit-gate-spanish-incomplete', html: true, full: true)
      check 'terms_accepted'
      assert_selector '#portal-edit-submit-gate-status', text: I18n.t('applications.submit_gate.ready', locale: :es), visible: :all
      take_evidence_screenshot('constituent-submit-gate-spanish-ready', html: true, full: true)
      save = find('input[name="save_draft"]')
      save.click
      assert_current_path constituent_portal_application_path(application, format: :html)
      visit edit_constituent_portal_application_path(application)
      assert_field 'application_household_size', with: '3'
      assert_selector '#portal-edit-submit-gate-status', text: I18n.t('applications.submit_gate.ready', locale: :es), visible: :all
      take_evidence_screenshot('constituent-submit-gate-spanish-restored', html: true, full: true)
    end
  end
end
