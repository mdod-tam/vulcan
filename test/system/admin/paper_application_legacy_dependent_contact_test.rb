# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'
require_relative '../../support/paper_application_context_helpers'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  class PaperApplicationLegacyDependentContactTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper
    include PaperApplicationContextHelpers
    include SystemTestEvidence

    setup do
      admin = create(:admin)
      system_test_sign_in(admin)
      setup_paper_application_context
      setup_fpl_policies

      visit new_admin_paper_application_path
      assert_selector 'h1', text: 'Apply for Constituent'
    end

    teardown do
      teardown_paper_application_context
    end

    test 'existing dependent keeps legacy primary contact while updating dependent preferences' do
      guardian = create(
        :constituent,
        first_name: 'Legacy',
        last_name: 'Guardian',
        email: 'legacy.guardian@example.com',
        phone: '202-555-0101',
        locale: 'en',
        communication_preference: 'email'
      )
      dependent = create(
        :constituent,
        first_name: 'Legacy',
        last_name: 'Dependent',
        email: 'legacy.dependent@example.com',
        phone: '202-555-0199',
        phone_type: 'voice',
        dependent_email: nil,
        dependent_phone: nil,
        locale: 'en',
        communication_preference: 'email'
      )
      create(
        :guardian_relationship,
        guardian_user: guardian,
        dependent_user: dependent,
        relationship_type: 'Parent'
      )

      select_existing_dependent(guardian, dependent)

      assert_not find_by_id('use_guardian_email_checkbox').checked?
      assert_not find_by_id('use_guardian_phone_checkbox').checked?
      assert_field 'constituent[dependent_email]', with: dependent.email
      assert_field 'constituent[dependent_phone]', with: dependent.phone

      select 'Spanish', from: 'dependent_constituent_locale'
      choose 'dependent_constituent_communication_preference_letter'
      take_evidence_screenshot('paper-legacy-dependent-contact-and-preferences', full: true, html: true)

      fill_in_application_details(household_size: 2, annual_income: 14_000)
      fill_in_disability_information
      fill_in_medical_provider_information(
        name: 'Dr. Existing Dependent',
        phone: '555-444-0093',
        email: 'dr.existing.dependent@example.com'
      )
      attach_and_accept_proofs
      complete_paper_application_attestations

      assert_button 'Submit Paper Application', disabled: false, wait: 10
      assert_difference 'Application.count', 1 do
        assert_no_difference 'User.count' do
          click_button 'Submit Paper Application'
          assert_selector 'h1', text: 'Application #', wait: 20
        end
      end

      application = Application.order(:id).last
      assert_equal dependent.id, application.user_id
      assert_equal guardian.id, application.managing_guardian_id
      assert_equal 'en', guardian.reload.locale
      assert_equal 'email', guardian.communication_preference

      dependent.reload
      assert_equal 'legacy.dependent@example.com', dependent.email
      assert_equal 'es', dependent.locale
      assert_equal 'letter', dependent.communication_preference
      take_evidence_screenshot('paper-legacy-dependent-application-created', full: true, html: true)
    end

    private

    def select_existing_dependent(guardian, dependent)
      choose 'A Dependent (minor or adult requiring guardian)', allow_label_click: true
      within 'fieldset', text: 'Guardian Information' do
        fill_in 'guardian_search_q', with: guardian.full_name
      end
      within '#guardian_search_results' do
        find('li', text: /#{Regexp.escape(guardian.full_name)}/i, wait: 10).click
      end
      within '[data-guardian-picker-target="dependentsFrame"]' do
        within 'li', text: dependent.full_name, wait: 15 do
          click_button 'Select'
        end
      end

      assert_equal dependent.id.to_s, first("input[name='dependent_id']", visible: :all).value
      select 'Parent', from: 'relationship_type'
    end
  end
end
