# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  class PaperIdentityReviewTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper
    include SystemTestEvidence

    PROOFS = %w[income_proof residency_proof id_proof medical_certification].freeze

    setup do
      @admin = create(:admin)
      setup_fpl_policies
      system_test_sign_in(@admin)
    end

    test 'consolidated paper decisions preserve uploads and resolve cases for every role' do
      exercise_self_keep_separate
      exercise_self_selection
      guardian = exercise_guardian_decision
      exercise_dependent_decision(guardian)
      exercise_hard_contact_conflict
    end

    test 'an old page submits native files through the compatibility route and retries with saved uploads' do
      create(:constituent, first_name: 'Legacy', last_name: 'Applicant', date_of_birth: Date.new(1980, 1, 15))
      start_self('Legacy', 'Applicant')
      complete_application
      # Reproduce PR 205's file inputs and clear -> requestSubmit contract.
      page.execute_script(<<~JS, identity_review_admin_paper_applications_path, PROOFS)
        const [url, proofs] = arguments;
        const form = document.getElementById(proofs[0]).form;
        proofs.forEach(key => {
          const input = document.getElementById(key);
          input.removeAttribute("data-direct-upload-url");
          input.name = key;
        });
        let bypass = false;
        form.addEventListener("submit", async event => {
          if (bypass) return;
          event.preventDefault();
          event.stopImmediatePropagation();
          const response = await fetch(url, {
            method: "POST",
            headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" }
          });
          const payload = await response.json();
          if (payload.state !== "clear") throw new Error("Legacy submission could not resume");
          bypass = true;
          try { form.requestSubmit(event.submitter); } finally { bypass = false; }
        }, true);
      JS
      assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'] do
        click_button 'Submit Paper Application'
        assert_selector '#identity-review-heading'
      end
      original = uploaded_ids
      assert_equal 4, original.size
      capture('legacy-review-retains-native-files')
      fill_in 'identity_rationale', with: 'Paper documents identify a different person.'
      assert_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'], 1 do
        click_button 'These are different people — create a new person'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      application = Application.order(:id).last
      PROOFS.each { |key| assert_equal original[key], application.public_send(key).blob.signed_id }
      capture('legacy-retry-application')
    end

    private

    def exercise_self_keep_separate
      candidate = create(:constituent, first_name: 'Review', last_name: 'Applicant', date_of_birth: Date.new(1980, 1, 15))
      start_self('Review', 'Applicant')
      complete_application
      assert_button 'Submit Paper Application', disabled: false
      capture('initial-form')
      click_button 'Submit Paper Application'
      assert_selector '#identity-review-heading'
      original = uploaded_ids
      assert_equal 4, original.size
      assert_field 'constituent[first_name]', with: 'Review', disabled: false
      assert_field 'application[household_size]', with: '2'
      assert_checked_field 'applicant_attributes[hearing_disability]'
      assert_checked_field 'application[information_verified]'
      capture('self-review-with-uploads')

      candidate.update!(city: 'Annapolis')
      fill_in 'identity_rationale', with: 'Paper documents identify a different person.'
      click_button 'These are different people — create a new person'
      assert_text 'changed since you reviewed them'
      assert_equal original, uploaded_ids
      capture('stale-review-retains-uploads')

      attach_file 'income_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
      within find_by_id('id_proof').ancestor('[data-controller="document-proof-handler"]') do
        click_button 'Remove document'
      end
      assert_no_selector 'input[type=hidden][name=id_proof_signed_id]', visible: :all
      attach_file 'id_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
      fill_in 'identity_rationale', with: 'Paper documents identify a different person.'
      assert_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'], 1 do
        click_button 'These are different people — create a new person'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      application = Application.order(:id).last
      PROOFS.each { |key| assert application.public_send(key).attached? }
      assert_not_equal original['income_proof'], application.income_proof.blob.signed_id
      review_case = DuplicateReviewCase.order(:id).last
      assert review_case.resolved_ignored?
      capture('keep-separate-application')
      visit admin_duplicate_review_path(review_case)
      assert_text 'Paper documents identify a different person.'
      capture('keep-separate-case')
      visit admin_duplicate_reviews_path
      assert_selector 'h1', text: 'Duplicate Review Queue'
      assert_no_selector "[data-testid='duplicate-review-case-row'][data-case-id='#{review_case.id}']"
      capture('queue-after-inline-decision')
    end

    def exercise_self_selection
      candidate = create(:constituent, first_name: 'Existing', last_name: 'Applicant', date_of_birth: Date.new(1980, 1, 15))
      start_self('Existing', 'Applicant')
      complete_application
      click_button 'Submit Paper Application'
      assert_selector '#identity-review-heading'
      original = uploaded_ids
      fill_in 'identity_rationale', with: 'Staff confirmed the existing person.'
      click_button 'Select this person'
      assert_selector '#review_contact_verified'
      assert_equal original, uploaded_ids
      assert_button 'Submit Paper Application', disabled: true
      capture('selected-person-needs-verification')
      check 'review_contact_verified'
      assert_no_difference 'User.count' do
        assert_difference ['Application.count', 'DuplicateReviewCase.count'], 1 do
          click_button 'Submit Paper Application'
          assert_selector 'h1', text: 'Application #', wait: 20
        end
      end
      assert_equal candidate.id, Application.order(:id).last.user_id
      review_case = DuplicateReviewCase.order(:id).last
      assert review_case.resolved_selected?
      visit admin_duplicate_review_path(review_case)
      assert_text 'Staff selected an existing person'
      assert_no_text 'no longer exists'
      capture('selected-person-case')
    end

    def exercise_guardian_decision
      create(:constituent, first_name: 'Review', last_name: 'Guardian', date_of_birth: Date.new(1980, 1, 15))
      visit new_admin_paper_application_path
      choose 'applicant_is_minor'
      within '#guardian-info-section' do
        click_link 'Create New Guardian'
        {
          first_name: 'Review', last_name: 'Guardian', date_of_birth: '01/15/1980',
          email: 'new.guardian@example.com', phone: '2025550199',
          physical_address_1: '456 Review Avenue', city: 'Baltimore', state: 'MD', zip_code: '21202'
        }.each { |key, value| fill_in "guardian_attributes[#{key}]", with: value }
        choose 'guardian_phone_type_voice'
        choose 'guardian_communication_preference_email'
        click_button 'Save Guardian'
        assert_selector '#guardian-review-heading'
        fill_in 'guardian_identity_rationale', with: 'The paper identifies a different guardian.'
        capture('guardian-review')
        assert_difference ['User.count', 'DuplicateReviewCase.count'], 1 do
          click_button 'These are different people — create a new person'
          assert_selector '[data-guardian-picker-target="selectedPane"]', text: 'Review Guardian'
        end
      end
      capture('guardian-created')
      User.find_by!(email: 'new.guardian@example.com')
    end

    def exercise_dependent_decision(guardian)
      create(:constituent, first_name: 'Review', last_name: 'Dependent', date_of_birth: Date.new(2014, 1, 15))
      visit new_admin_paper_application_path
      choose 'applicant_is_minor'
      fill_in 'guardian_search_q', with: guardian.full_name
      within '#guardian_search_results' do
        find("li[data-user-id='#{guardian.id}']", wait: 10).click
      end
      within '#dependent-info-section' do
        fill_in 'constituent[first_name]', with: 'Review'
        fill_in 'constituent[last_name]', with: 'Dependent'
        fill_in 'constituent[date_of_birth]', with: '01/15/2014'
        select 'Parent', from: 'relationship_type'
      end
      complete_application
      click_button 'Submit Paper Application'
      assert_selector '#identity-review-heading'
      assert_equal 4, uploaded_ids.size
      assert_field 'guardian_id', with: guardian.id.to_s, type: 'hidden'
      assert_no_text 'Dependent identity review refused the write'
      fill_in 'identity_rationale', with: 'This is a different dependent.'
      capture('dependent-review')
      assert_difference ['User.count', 'Application.count', 'GuardianRelationship.count', 'DuplicateReviewCase.count'], 1 do
        click_button 'These are different people — create a new person'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      assert_equal 'dependent', DuplicateReviewCase.order(:id).last.metadata['intake_role']
      capture('dependent-application')
    end

    def exercise_hard_contact_conflict
      owner = create(:constituent)
      start_self('Contact', 'Conflict')
      fill_in 'constituent[email]', with: owner.email
      complete_application
      click_button 'Submit Paper Application'
      assert_selector '#identity-review-heading'
      assert_text 'An existing record uses this contact information.'
      assert_no_button 'These are different people — create a new person'
      assert_button 'Select this person'
      assert_equal 4, uploaded_ids.size
      capture('hard-contact-conflict')
    end

    def start_self(first_name, last_name)
      visit new_admin_paper_application_path
      click_button 'Create New Applicant'
      fill_in_applicant_information(first_name: first_name, last_name: last_name,
                                    phone: "202555#{format('%04d', SecureRandom.random_number(10_000))}")
    end

    def complete_application
      attach_and_accept_proofs
      fill_in_application_details(household_size: 2, annual_income: 20_000)
      fill_in_disability_information
      fill_in_medical_provider_information
      complete_paper_application_attestations
    end

    # Exercise the rendered sections without the legacy helper's DOM visibility overrides.
    def reveal_adult_application_sections
      assert_selector '#self-info-section', visible: true
    end

    def reveal_paper_application_common_sections
      assert_selector '#proof-heading', visible: true
    end

    def uploaded_ids
      PROOFS.to_h do |key|
        assert_text(/Uploaded:/)
        assert_equal '', find_by_id(key).value
        [key, find("input[type=hidden][name='#{key}_signed_id']", visible: :all).value]
      end
    end

    def capture(label)
      take_evidence_screenshot("paper-consolidation-#{label}", full: true, html: true)
    end
  end
end
