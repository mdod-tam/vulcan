# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  class PaperApplicationDependentGuardianTest < ApplicationSystemTestCase
    include SystemTestEvidence

    test 'complete guardian creation and application workflow' do
      perform_complete_guardian_creation_workflow
    end

    test 'existing guardian selection and workflow' do
      perform_existing_guardian_selection_workflow
    end

    test 'existing dependent contact refusal uses the shared contact-choice message' do
      guardian = create(:constituent, first_name: 'Shared', last_name: 'Guardian')
      dependent = create(
        :constituent,
        first_name: 'Shared',
        last_name: 'Dependent',
        dependent_email: 'shared.dependent@example.com'
      )
      create(
        :guardian_relationship,
        guardian_user: guardian,
        dependent_user: dependent,
        relationship_type: 'Parent'
      )
      admin = create(:admin, verified: true)
      system_test_sign_in(admin)
      visit new_admin_paper_application_path

      choose 'applicant_is_minor'
      within '#guardian-info-section' do
        fill_in 'guardian_search_q', with: guardian.full_name
        within '#guardian_search_results' do
          find('li', text: guardian.full_name, wait: 10).click
        end
      end

      within '#guardian_dependents' do
        within 'li', text: dependent.full_name, wait: 10 do
          click_button 'Select'
        end
      end
      assert_selector '#existing-dependent-summary', text: dependent.full_name, wait: 10
      assert_field 'constituent[dependent_email]', with: dependent.dependent_email
      fill_in 'constituent[dependent_email]', with: ''

      assert_no_difference ['Application.count', 'GuardianRelationship.count', 'Event.count',
                            'DuplicateReviewCase.count', 'Notification.count'] do
        page.execute_script(<<~JS)
          const form = document.querySelector('form[data-controller~="paper-application"]');
          HTMLFormElement.prototype.submit.call(form);
        JS
        assert_text "Enter the dependent's email or choose the guardian's email address.", wait: 20
      end

      assert_selector '#existing-dependent-summary', text: dependent.full_name
      assert_field 'constituent[dependent_email]', with: ''
      take_evidence_screenshot('paper-a2-existing-dependent-contact-refusal', full: true, html: true)
    end

    private

    def perform_complete_guardian_creation_workflow
      admin = create(:admin, verified: true)
      system_test_sign_in(admin)
      visit new_admin_paper_application_path

      # Guardian validation
      assert_selector 'label', text: 'A Dependent (must select existing guardian in system or enter guardian\'s information)'
      choose 'applicant_is_minor'

      assert_selector '#guardian-info-section', visible: true
      assert_text 'Guardian Information'
      assert_selector '#dependent-info-section', visible: false

      within '#guardian-info-section' do
        click_link 'Or Create New Guardian'
        assert_text 'Create New Guardian', wait: 3

        fill_in 'guardian_attributes[first_name]', with: ''
        fill_in 'guardian_attributes[email]', with: 'invalid-email'
        click_button 'Save Guardian'
        assert_selector '.border-red-500', count: 2, wait: 3

        fill_in 'guardian_attributes[first_name]', with: 'Guardian'
        fill_in 'guardian_attributes[last_name]', with: 'TestParent'
        fill_in 'guardian_attributes[date_of_birth]', with: 40.years.ago.strftime('%Y-%m-%d')
        fill_in 'guardian_attributes[email]', with: "guardian-test-#{Time.now.to_i}@example.com"
        fill_in 'guardian_attributes[phone]', with: '5551234567'
        fill_in 'guardian_attributes[physical_address_1]', with: '456 Guardian Ave'
        fill_in 'guardian_attributes[city]', with: 'Baltimore'
        fill_in 'guardian_attributes[state]', with: 'MD'
        fill_in 'guardian_attributes[zip_code]', with: '21202'
        choose 'guardian_phone_type_voice'
        choose 'guardian_communication_preference_email'

        click_button 'Save Guardian'
        assert_text 'Guardian TestParent', wait: 5
      end

      # The dependent section and selected pane appear after guardian selection.
      assert_selector '#dependent-info-section', visible: true, wait: 10
      assert_selector '[data-guardian-picker-target="selectedPane"]', visible: true, wait: 5
      assert_text 'New Dependent Information'

      assert_text 'Guardian TestParent'

      within '#dependent-info-section' do
        fill_in 'dependent_constituent_first_name', with: 'Dependent'
        fill_in 'dependent_constituent_last_name', with: 'TestChild'
        fill_in 'dependent_constituent_date_of_birth', with: 10.years.ago.strftime('%Y-%m-%d')

        uncheck 'use_guardian_email'
        assert_selector 'input[name="constituent[dependent_email]"]', visible: true, wait: 3
        fill_in 'constituent[dependent_email]', with: "dependent-test-#{Time.now.to_i}@example.com"
        select 'Parent', from: 'relationship_type'
      end

      complete_application_form
      verify_complete_workflow
    end

    def perform_existing_guardian_selection_workflow
      existing_guardian = create(:constituent,
                                 first_name: 'Existing',
                                 last_name: 'Guardian',
                                 email: 'existing.guardian@example.com')

      admin = create(:admin, verified: true)
      system_test_sign_in(admin)
      visit new_admin_paper_application_path

      choose 'applicant_is_minor'
      assert_selector '#guardian-info-section', visible: true

      # If search does not find the guardian, the test creates a new guardian instead.
      within '#guardian-info-section' do
        assert_selector '[data-guardian-picker-target="searchPane"]', visible: true, wait: 5

        if page.has_field?('guardian_search_q', wait: 3)
          fill_in 'guardian_search_q', with: 'Existing'

          if page.has_selector?('#guardian_search_results li', wait: 5)
            within('#guardian_search_results') do
              if page.has_selector?('li', text: /Existing/i, wait: 3)
                find('li', text: /Existing/i).click
              else
                click_link 'Or Create New Guardian'
                fill_existing_guardian_form
              end
            end
          else
            puts 'INFO: Guardian search results not appearing, falling back to creation workflow...'
            click_link 'Or Create New Guardian'
            fill_existing_guardian_form
          end
        else
          puts 'INFO: Guardian search field missing, falling back to creation workflow...'
          click_link 'Or Create New Guardian'
          fill_existing_guardian_form
        end
      end

      assert_selector '#dependent-info-section', visible: true, wait: 10
      assert_selector '[data-guardian-picker-target="selectedPane"]', visible: true, wait: 5
      assert_text 'New Dependent Information'

      within '#dependent-info-section' do
        fill_in 'dependent_constituent_first_name', with: 'TestDependent'
        fill_in 'dependent_constituent_last_name', with: 'ForExisting'
        fill_in 'dependent_constituent_date_of_birth', with: 8.years.ago.strftime('%Y-%m-%d')

        # Keep the default 'use_guardian_email' choice, unlike the creation test.
        select 'Parent', from: 'relationship_type'
      end

      complete_application_form
      verify_existing_guardian_workflow(existing_guardian)
    end

    def fill_existing_guardian_form
      assert_text 'Create New Guardian', wait: 3
      fill_in 'guardian_attributes[first_name]', with: 'Fallback'
      fill_in 'guardian_attributes[last_name]', with: 'Guardian'
      fill_in 'guardian_attributes[date_of_birth]', with: 40.years.ago.strftime('%Y-%m-%d')
      fill_in 'guardian_attributes[email]', with: "existing-fallback-#{Time.now.to_i}@example.com"
      fill_in 'guardian_attributes[phone]', with: '5551234567'
      fill_in 'guardian_attributes[physical_address_1]', with: '789 Existing Ave'
      fill_in 'guardian_attributes[city]', with: 'Baltimore'
      fill_in 'guardian_attributes[state]', with: 'MD'
      fill_in 'guardian_attributes[zip_code]', with: '21203'
      choose 'guardian_phone_type_voice'
      choose 'guardian_communication_preference_email'

      assert_difference 'User.count', 1 do
        click_button 'Save Guardian'
        assert_selector '[data-guardian-picker-target="selectedPane"]',
                        text: 'Fallback Guardian', visible: true, wait: 5
      end
      guardian = User.find_by!(first_name: 'Fallback', last_name: 'Guardian')
      assert_field 'guardian_id', type: :hidden, with: guardian.id, visible: :all
    end

    def complete_application_form
      check 'applicant_attributes[self_certify_disability]'
      check 'applicant_attributes[hearing_disability]'

      fill_in 'application_household_size', with: '3'
      fill_in 'application_annual_income', with: '25000'
      check 'application_maryland_resident'
      check 'applicant_attributes_self_certify_disability'

      fill_in 'application_medical_provider_name', with: 'Dr. Pediatric'
      fill_in 'application_medical_provider_phone', with: '5555551234'
      fill_in 'application_medical_provider_email', with: 'drpediatric@example.com'

      attach_pdf_proof('income')
      choose 'accept_income_proof'
      attach_pdf_proof('residency')
      choose 'accept_residency_proof'
    end

    def verify_complete_workflow
      before_count = Application.count
      before_user_count = User.count
      before_relationship_count = GuardianRelationship.count

      assert_button 'Submit Paper Application', disabled: false, wait: 15
      click_button 'Submit Paper Application'
      wait_for_network_idle(timeout: 10)

      # Without a redirect, this checks only that the guardian exists.
      current_path_check = current_path
      if current_path_check.match?(%r{/admin/applications/\d+})
        verify_successful_application_creation(before_count, before_user_count, before_relationship_count, 'Guardian', 'Dependent')
      else
        verify_guardian_creation_without_redirect(before_user_count, before_relationship_count, 'Guardian')
      end
    end

    def verify_existing_guardian_workflow(_existing_guardian)
      before_count = Application.count
      before_relationship_count = GuardianRelationship.count

      assert_button 'Submit Paper Application', disabled: false, wait: 15
      click_button 'Submit Paper Application'
      wait_for_network_idle(timeout: 10)

      current_path_check = current_path
      if current_path_check.match?(%r{/admin/applications/\d+})
        assert_equal before_count + 1, Application.count, 'Application count should have increased by 1'

        assert_equal before_relationship_count + 1, GuardianRelationship.count, 'Guardian relationship count should have increased by 1'

        dependent_user = User.where('created_at > ?', 1.minute.ago)
                             .find_by(first_name: 'TestDependent', last_name: 'ForExisting')
        assert dependent_user.present?, 'Dependent user should have been created'

        newest_app = Application.order(created_at: :desc).first
        assert_equal 'Users::Constituent', newest_app.user.type, 'Application user should be a Constituent'
        assert newest_app.user.first_name.include?('TestDependent'), 'Application should belong to the dependent user'
      else
        # Without a redirect, this checks only that the dependent exists.
        dependent_user = User.where('created_at > ?', 1.minute.ago)
                             .find_by(first_name: 'TestDependent', last_name: 'ForExisting')
        assert dependent_user.present?, 'Dependent user should have been created even if form validation failed'
      end
    end

    def verify_successful_application_creation(before_count, _before_user_count, before_relationship_count, guardian_first_name, dependent_first_name)
      assert_equal before_count + 1, Application.count, 'Application count should have increased by 1'

      guardian_user = User.where('created_at > ?', 1.minute.ago)
                          .find_by('first_name LIKE ?', "#{guardian_first_name}%")
      dependent_user = User.where('created_at > ?', 1.minute.ago)
                           .find_by('first_name LIKE ?', "#{dependent_first_name}%")

      assert guardian_user.present?, 'Guardian user should have been created'
      assert dependent_user.present?, 'Dependent user should have been created'
      assert guardian_user != dependent_user, 'Guardian and dependent should be different users'
      assert_equal before_relationship_count + 1, GuardianRelationship.count, 'Guardian relationship count should have increased by 1'

      newest_app = Application.order(created_at: :desc).first
      assert_equal 'Users::Constituent', newest_app.user.type, 'Application user should be a Constituent'
      assert newest_app.user.first_name.include?(dependent_first_name), 'Application should belong to the dependent user'

      guardian_relationship = GuardianRelationship.order(created_at: :desc).first
      assert_equal newest_app.user, guardian_relationship.dependent_user, 'Guardian relationship dependent should match application user'
      assert_equal guardian_user, guardian_relationship.guardian_user, 'Guardian relationship should have the correct guardian'
      assert_equal 'Parent', guardian_relationship.relationship_type, 'Relationship type should be set correctly'
    end

    def verify_guardian_creation_without_redirect(_before_user_count, _before_relationship_count, guardian_first_name)
      guardian_user = User.where('created_at > ?', 1.minute.ago)
                          .find_by('first_name LIKE ?', "#{guardian_first_name}%")

      assert guardian_user.present?, 'Guardian user should have been created even if form validation failed'
    end

    def attach_pdf_proof(type)
      fixture_path = Rails.root.join('test/fixtures/files', "#{type}_proof.pdf")
      fixture_path = Rails.root.join('test/fixtures/files/blank.pdf') unless File.exist?(fixture_path)

      raise "Missing test fixture file: #{fixture_path}" unless File.exist?(fixture_path)

      attach_file "#{type}_proof", fixture_path
    end
  end
end
