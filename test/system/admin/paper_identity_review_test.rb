# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'
require_relative '../../support/paper_application_context_helpers'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  # Browser evidence for paper identity review.
  #
  # The property that justifies the whole design is here rather than in any unit test: the four
  # proof inputs are native file inputs with no direct upload, so a server-rendered failure would
  # discard documents staff had already chosen. Every flow below therefore checks that the selected
  # filenames survive whatever the server said.
  class PaperIdentityReviewTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper
    include PaperApplicationContextHelpers
    include SystemTestEvidence

    # Every proof the form accepts, because accepting a proof without attaching its document is a
    # server-side validation failure that has nothing to do with identity review.
    PROOFS = {
      'medical_certification' => 'medical_certification_valid.pdf',
      'income_proof' => 'income_proof.pdf',
      'residency_proof' => 'residency_proof.pdf',
      'id_proof' => 'residency_proof.pdf'
    }.freeze

    setup do
      @admin = create(:admin)
      system_test_sign_in(@admin)
      setup_paper_application_context
      Current.paper_context = true
      setup_fpl_policies

      visit new_admin_paper_application_path
      assert_selector 'h1', text: 'Apply for Constituent'
      reveal_adult_application_sections
    end

    test 'an applicant with no matches submits once with its documents attached' do
      fill_paper_form(first_name: 'Clear', last_name: 'Applicant')
      attach_proofs

      assert_difference ['User.count', 'Application.count'], 1 do
        submit_and_settle
        assert_created_without_refusal
      end
      assert_no_selector '[data-paper-application-target="identityReviewPanel"]', visible: true
      application = Application.order(:id).last
      assert application.income_proof.attached?, 'the documents must reach the application'
    end

    test 'a soft match shows the decision panel and keeps the chosen files selected' do
      create(:constituent, first_name: 'Soft', last_name: 'Matcher', date_of_birth: Date.new(1980, 1, 15))
      fill_paper_form(first_name: 'Soft', last_name: 'Matcher')
      attach_proofs

      assert_no_difference ['User.count', 'Application.count'] do
        submit_and_settle
      end

      panel = find('[data-paper-application-target="identityReviewPanel"]')
      assert panel.text.include?('Soft Matcher'), 'staff must see who was matched'
      assert_equal 'identity-review-heading', page.evaluate_script('document.activeElement.id')
      assert_filenames_survived
      take_evidence_screenshot('paper-identity-review-possible-matches', full: true, html: true)
    end

    test 'an override creates one application and one confirmation event' do
      create(:constituent, first_name: 'Override', last_name: 'Case', date_of_birth: Date.new(1980, 1, 15))
      fill_paper_form(first_name: 'Override', last_name: 'Case')
      attach_proofs
      submit_and_settle

      assert_difference ['User.count', 'Application.count'], 1 do
        assert_difference "Event.where(action: 'paper_identity_no_match_confirmed').count", 1 do
          click_button 'These are different people — create a new constituent'
          assert_no_selector '[data-paper-application-target="identityReviewPanel"]', visible: true, wait: 10
        end
      end

      assert_equal 0, DuplicateReviewCase.where(source: :paper_intake).count,
                   'a decided override must not also queue a review case'
    end

    test 'an exact contact conflict offers no override and clears after a correction' do
      existing = create(:constituent, email: "conflict-#{SecureRandom.hex(3)}@example.com")
      fill_paper_form(first_name: 'Conflict', last_name: 'Case', email: existing.email)
      attach_proofs

      assert_no_difference ['User.count', 'Application.count'] do
        submit_and_settle
      end

      panel = find('[data-paper-application-target="identityReviewPanel"]')
      assert_match(/already associated with an existing record/i, panel.text)
      assert_no_selector '[data-paper-application-target="identityReviewOverride"]', visible: true
      assert_filenames_survived
      assert_applicant_fields_survived(first_name: 'Conflict', last_name: 'Case')
      take_evidence_screenshot('paper-identity-review-contact-block', full: true, html: true)

      # Correcting the contact must let the application through without reselecting documents.
      find('input[name="constituent[email]"]:not([disabled])').set("corrected-#{SecureRandom.hex(3)}@example.com")
      assert_filenames_survived
      assert_applicant_fields_survived(first_name: 'Conflict', last_name: 'Case')

      assert_difference 'Application.count', 1 do
        submit_and_settle
      end
    end

    # The copy tells staff to go and sign in somewhere else and come back, which is only safe advice
    # if this page really does survive it. Everything below the notice is that promise being kept:
    # the typed applicant, the four selected documents, and finally a successful submission from the
    # original tab without re-choosing a single file.
    test 'an expired session explains the recovery and the page survives it' do
      fill_paper_form(first_name: 'Session', last_name: 'Expired')
      attach_proofs

      # Production-shaped: the session record is gone, so the next request is redirected to sign-in
      # exactly as it would be after a timeout or a revoked session. Nothing about the request the
      # browser makes is special-cased for the test.
      Session.delete_all

      assert_no_difference ['User.count', 'Application.count'] do
        submit_and_settle
      end

      notice = find('[data-paper-application-target="identityReviewNotice"]')
      assert_match(/session has expired/i, notice.text)
      assert_match(/another browser tab/i, notice.text)
      assert_filenames_survived
      assert_applicant_fields_survived(first_name: 'Session', last_name: 'Expired')
      take_evidence_screenshot('paper-identity-review-session-expired', full: true, html: true)

      recover_session_in_another_tab

      assert_difference ['User.count', 'Application.count'], 1 do
        submit_and_settle
        assert_created_without_refusal
      end
      assert Application.order(:id).last.income_proof.attached?,
             'the documents chosen before the session expired must be the ones that arrive'
    end

    # The one state that also disables Submit, so if it is not visible the button appears to have
    # stopped working for no reason.
    test 'the checking state is visible while the review is in flight' do
      fill_paper_form(first_name: 'Checking', last_name: 'State')
      attach_proofs
      hold_identity_review_open

      click_button 'Submit Paper Application'
      assert_selector '[data-paper-application-target="identityReviewPanel"]',
                      text: /Checking for existing/i, wait: 10
      assert_button 'Submit Paper Application', disabled: true
      take_evidence_screenshot('paper-identity-review-checking', full: true, html: true)

      release_identity_review
      assert_no_selector '[data-paper-application-target="identityReviewPanel"]',
                         text: /Checking for existing/i, wait: 20
    end

    # A request that never settles used to leave the form gated forever, with four selected files a
    # reload would discard. The wait is the real 15s bound rather than a shortened one, because the
    # bound is the behaviour under test.
    test 'a review that never answers times out and returns the form to usable' do
      fill_paper_form(first_name: 'Timeout', last_name: 'State')
      attach_proofs
      hold_identity_review_open

      click_button 'Submit Paper Application'
      assert_selector '[data-paper-application-target="identityReviewPanel"]',
                      text: /timed out/i, wait: 25
      assert_button 'Submit Paper Application', disabled: false
      assert_filenames_survived
      take_evidence_screenshot('paper-identity-review-timed-out', full: true, html: true)
    end

    test 'a failed review shows a visible retry and preserves the form' do
      fill_paper_form(first_name: 'Retry', last_name: 'Case')
      attach_proofs
      stub_identity_review_failure

      assert_no_difference ['User.count', 'Application.count'] do
        submit_and_settle
      end

      notice = find('[data-paper-application-target="identityReviewNotice"]')
      assert_match(/Submit again to retry/i, notice.text)
      assert_filenames_survived
      take_evidence_screenshot('paper-identity-review-error-retry', full: true, html: true)

      restore_identity_review
      assert_difference 'Application.count', 1 do
        submit_and_settle
      end
    end

    test 'an expired review says so, drops the token, and refreshes on resubmission' do
      create(:constituent, first_name: 'Expiry', last_name: 'Case', date_of_birth: Date.new(1980, 1, 15))
      fill_paper_form(first_name: 'Expiry', last_name: 'Case')
      attach_proofs
      submit_and_settle
      assert_selector '[data-paper-application-target="identityReviewPanel"]', visible: true

      expire_open_review

      panel = find('[data-paper-application-target="identityReviewPanel"]')
      assert_match(/Review expired/i, panel.text)
      assert_match(/refresh the matches/i, panel.text)
      assert_equal '', find('[data-paper-application-target="identityDecision"]', visible: :all).value
      assert_filenames_survived
      take_evidence_screenshot('paper-identity-review-expired', full: true, html: true)

      assert_no_difference 'Application.count' do
        submit_and_settle
      end
      assert_selector '[data-paper-application-target="identityReviewPanel"]', visible: true
    end

    test 'selecting an eligible match enters the existing-applicant verification flow' do
      eligible = create(:constituent, first_name: 'Eligible', last_name: 'Match',
                                      date_of_birth: Date.new(1980, 1, 15))
      fill_paper_form(first_name: 'Eligible', last_name: 'Match')
      attach_proofs
      submit_and_settle

      assert_no_difference 'User.count' do
        click_button "Use this constituent: #{eligible.full_name}"
        assert_selector '[name="existing_constituent_id"]', visible: :all, wait: 10
      end

      assert_equal eligible.id.to_s, find('[name="existing_constituent_id"]', visible: :all).value
      assert_filenames_survived
      # Verification gating must be active before anything can be submitted.
      assert_button 'Submit Paper Application', disabled: true
      take_evidence_screenshot('paper-identity-review-eligible-selected', full: true, html: true)
    end

    test 'an ineligible match stays unselected and says why' do
      ineligible = create(:constituent, first_name: 'Blocked', last_name: 'Match',
                                        date_of_birth: Date.new(1980, 1, 15))
      create(:application, :in_progress, user: ineligible, application_date: Date.current)

      fill_paper_form(first_name: 'Blocked', last_name: 'Match')
      attach_proofs
      submit_and_settle

      assert_no_difference ['User.count', 'Application.count'] do
        click_button "Use this constituent: #{ineligible.full_name}"
        assert_match(/active application/i, find('[data-paper-application-target="identityReviewBody"]').text)
      end

      assert_equal '', find('[name="existing_constituent_id"]', visible: :all).value
      assert_filenames_survived
      take_evidence_screenshot('paper-identity-review-ineligible-match', full: true, html: true)
    end

    test 'dependent contact correction leads to on-file identity selection and submission' do
      guardian = create(:constituent, first_name: 'Selection', last_name: 'Guardian',
                                      email: "selection-guardian-#{SecureRandom.hex(3)}@example.com",
                                      phone: '202-555-0184')
      on_file = create(:constituent, first_name: 'Selection', last_name: 'Dependent',
                                     date_of_birth: Date.new(2012, 9, 14))
      create(:guardian_relationship, guardian_user: guardian, dependent_user: on_file,
                                     relationship_type: 'Parent')

      start_new_dependent_application(guardian)
      fill_new_dependent_identity(first_name: on_file.first_name, last_name: on_file.last_name,
                                  date_of_birth: on_file.date_of_birth.strftime('%m/%d/%Y'))
      within '#dependent-info-section' do
        uncheck 'use_guardian_email'
        find('input[name="constituent[dependent_email]"]:not([disabled])').set('')
      end
      complete_dependent_application

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                            'DuplicateReviewCase.count', 'Event.count', 'Notification.count'] do
        submit_and_settle
      end
      assert_selector '#identity-review-heading', text: 'Dependent contact information needed'
      assert_text "Enter the dependent's email or choose the guardian's email address."
      contact_field = find('input[name="constituent[dependent_email]"]:not([disabled])')
      assert_equal 'true', contact_field[:'aria-invalid']
      assert_equal contact_field[:id], page.evaluate_script('document.activeElement.id')
      assert_filenames_survived
      take_evidence_screenshot('paper-a2-dependent-contact-choice-refused', full: true, html: true)

      contact_field.set("selection-dependent-#{SecureRandom.hex(3)}@example.com")
      assert_no_selector '#identity-review-heading', text: 'Dependent contact information needed', wait: 10
      assert_nil contact_field[:'aria-invalid']
      assert_filenames_survived

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count'] do
        submit_and_settle
      end
      assert_selector '#identity-review-heading', text: 'Possible matching dependents'
      assert_button "Use this dependent: #{on_file.full_name}"
      assert_filenames_survived
      take_evidence_screenshot('paper-a2-dependent-on-file-match', full: true, html: true)

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                            'DuplicateReviewCase.count', 'Event.count', 'Notification.count'] do
        click_button "Use this dependent: #{on_file.full_name}"
        assert_selector '#existing-dependent-summary', text: on_file.full_name, wait: 15
      end
      assert_equal on_file.id.to_s, first("input[name='dependent_id']", visible: :all).value
      assert_text on_file.date_of_birth.to_fs(:long)
      assert_selector '#existing-dependent-summary [role="status"]',
                      text: /Existing dependent selected: #{Regexp.escape(on_file.full_name)}/
      select 'Parent', from: 'relationship_type'
      assert_filenames_survived
      take_evidence_screenshot('paper-a2-dependent-on-file-match-selected', full: true, html: true)

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'DuplicateReviewCase.count',
                            "Event.where(action: 'paper_identity_no_match_confirmed').count"] do
        assert_difference 'Application.count', 1 do
          submit_and_settle
          assert_created_without_refusal
        end
      end
      application = Application.order(:id).last
      assert_equal on_file.id, application.user_id
      assert_equal guardian.id, application.managing_guardian_id
    end

    test 'A2 dependent decisions remain visible through refusal correction and on-file selection' do
      guardian = create(:constituent, first_name: 'A2', last_name: 'Guardian',
                                      date_of_birth: Date.new(1980, 1, 15),
                                      email: "a2-guardian-#{SecureRandom.hex(3)}@example.com",
                                      phone: '202-555-0181', needs_duplicate_review: true)
      on_file = create(:constituent, first_name: 'Onfile', last_name: 'Dependent',
                                     date_of_birth: Date.new(2012, 9, 14))
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: on_file,
                                   relationship_type: 'Parent')
      soft_candidate = create(:constituent, first_name: 'Possible', last_name: 'Dependent',
                                            date_of_birth: Date.new(2010, 1, 15))

      choose 'A Dependent (minor or adult requiring guardian)', allow_label_click: true
      within '#guardian-info-section' do
        click_link 'Create New Guardian'
        fill_in 'guardian_attributes[first_name]', with: guardian.first_name
        fill_in 'guardian_attributes[last_name]', with: guardian.last_name
        fill_in 'guardian_attributes[date_of_birth]', with: guardian.date_of_birth.strftime('%m/%d/%Y')
        fill_in 'guardian_attributes[email]', with: "new-#{guardian.email}"
        fill_in 'guardian_attributes[phone]', with: '202-555-0199'
        fill_in 'guardian_attributes[physical_address_1]', with: '456 Review Avenue'
        fill_in 'guardian_attributes[city]', with: 'Baltimore'
        fill_in 'guardian_attributes[state]', with: 'MD'
        fill_in 'guardian_attributes[zip_code]', with: '21202'
        choose 'guardian_phone_type_voice'
        choose 'guardian_communication_preference_email'

        assert_no_difference ['User.count', 'DuplicateReviewCase.count', 'Event.count'] do
          click_button 'Save Guardian'
          assert_selector '#guardian-identity-review-heading',
                          text: 'Possible matching guardians', wait: 10
        end

        address = find_field('guardian_attributes[physical_address_1]')
        address.click
        address.set('457 Review Avenue')
        assert_selector '#guardian-identity-review-heading', text: 'Guardian details changed'
        assert_text 'Save Guardian to review again.'
        assert_no_button 'These are different people — create a new guardian'
        assert_equal address[:id], page.evaluate_script('document.activeElement.id')
        take_evidence_screenshot('paper-a2-guardian-review-invalidated-by-edit', full: true, html: true)
      end

      start_new_dependent_application(guardian)
      fill_new_dependent_identity(first_name: 'Possible', last_name: 'Dependent',
                                  date_of_birth: '01/15/2010')
      complete_dependent_application

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count'] do
        submit_and_settle
      end
      assert_selector '#identity-review-heading', text: 'Possible matching dependents'
      assert_text soft_candidate.full_name
      assert_text 'Not an eligible on-file dependent for this guardian'
      assert_no_button "Use this dependent: #{soft_candidate.full_name}"
      assert_button 'These are different people — create a new dependent'
      assert_no_button 'These are different people — create a new constituent'
      assert_equal 'identity-review-heading', page.evaluate_script('document.activeElement.id')
      assert_filenames_survived
      take_evidence_screenshot('paper-a2-dependent-soft-match', full: true, html: true)

      assert_difference ['User.count', 'GuardianRelationship.count', 'Application.count'], 1 do
        assert_difference "Event.where(action: 'paper_identity_no_match_confirmed').count", 1 do
          click_button 'These are different people — create a new dependent'
          assert_selector 'h1', text: 'Application #', wait: 20
        end
      end
      assert_equal 0, DuplicateReviewCase.where(source: :paper_intake).count
      take_evidence_screenshot('paper-a2-dependent-override-created', full: true, html: true)

      contact_owner = create(:constituent, email: "a2-contact-owner-#{SecureRandom.hex(3)}@example.com")
      start_new_dependent_application(guardian)
      fill_new_dependent_identity(first_name: 'Contact', last_name: 'Collision',
                                  date_of_birth: '02/16/2011', own_email: contact_owner.email)
      complete_dependent_application

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                            'DuplicateReviewCase.count', 'Event.count'] do
        submit_and_settle
      end
      assert_selector '#identity-review-heading', text: 'Existing contact information'
      assert_text(/already associated with an existing record/i)
      assert_text(/no eligible on-file dependent for this guardian is available to select/i)
      assert_text "Correct the dependent's entered contact information"
      assert_text 'Not an eligible on-file dependent for this guardian'
      assert_no_selector '[data-paper-application-target="identityReviewOverride"]', visible: true
      assert_filenames_survived
      take_evidence_screenshot('paper-a2-dependent-contact-block', full: true, html: true)

      find('input[name="constituent[dependent_email]"]:not([disabled])')
        .set("a2-corrected-#{SecureRandom.hex(3)}@example.com")
      assert_filenames_survived
      assert_difference ['User.count', 'GuardianRelationship.count', 'Application.count'], 1 do
        submit_and_settle
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      take_evidence_screenshot('paper-a2-dependent-contact-corrected', full: true, html: true)

      start_new_dependent_application(guardian)
      select_on_file_dependent(on_file)
      summary = find_by_id('existing-dependent-summary')
      assert_equal '-1', summary[:tabindex]
      assert_text on_file.full_name
      assert_text on_file.date_of_birth.to_fs(:long)
      assert_no_selector '#dependent_constituent_first_name', visible: :all
      assert_no_selector '#dependent_constituent_date_of_birth', visible: :all
      assert_selector '#existing-dependent-summary [role="status"]',
                      text: /Existing dependent selected: #{Regexp.escape(on_file.full_name)}/
      take_evidence_screenshot('paper-a2-dependent-on-file-summary', full: true, html: true)

      within '#dependent-info-section' do
        click_button 'Change Dependent'
      end
      assert_no_selector '#existing-dependent-summary', wait: 10
      assert_equal guardian.id.to_s, first("input[name='guardian_id']", visible: :all).value
      assert_equal '', first("input[name='dependent_id']", visible: :all).value
      focus_location = page.evaluate_script(<<~JS)
        (() => {
          const active = document.activeElement;
          const chooser = document.getElementById('guardian_dependents');
          return chooser && active && chooser.contains(active) ? 'dependents-list' : (active?.id || 'body');
        })()
      JS
      assert_equal 'dependents-list', focus_location
      take_evidence_screenshot('paper-a2-dependent-change-selection', full: true, html: true)
    end

    private

    def start_new_dependent_application(guardian)
      visit new_admin_paper_application_path
      assert_selector 'h1', text: 'Apply for Constituent'
      choose 'A Dependent (minor or adult requiring guardian)', allow_label_click: true
      within 'fieldset', text: 'Guardian Information' do
        fill_in 'guardian_search_q', with: guardian.full_name
      end
      within '#guardian_search_results' do
        find('li', text: /#{Regexp.escape(guardian.full_name)}/i, wait: 10).click
      end
      assert_selector "input[name='guardian_id'][value='#{guardian.id}']", visible: :all, wait: 10
      assert_selector '#dependent-info-section', visible: true, wait: 10
    end

    def fill_new_dependent_identity(first_name:, last_name:, date_of_birth:, own_email: nil)
      within '#dependent-info-section' do
        find('input[name="constituent[first_name]"]:not([disabled])').set(first_name)
        find('input[name="constituent[last_name]"]:not([disabled])').set(last_name)
        find('input[name="constituent[date_of_birth]"]:not([disabled])').set(date_of_birth)
        if own_email
          uncheck 'use_guardian_email' if has_checked_field?('use_guardian_email', wait: 2)
          find('input[name="constituent[dependent_email]"]:not([disabled])').set(own_email)
        end
        select 'Parent', from: 'relationship_type'
      end
    end

    def complete_dependent_application
      fill_in_application_details(household_size: 2, annual_income: 20_000)
      fill_in_disability_information
      fill_in_medical_provider_information(name: 'Dr. A2 Evidence', phone: '2025559876',
                                           email: 'dr.a2@example.com')
      attach_proofs
      complete_paper_application_attestations
      assert_button 'Submit Paper Application', disabled: false, wait: 10
    end

    def select_on_file_dependent(dependent)
      frame = find('[data-guardian-picker-target="dependentsFrame"]', text: dependent.full_name, wait: 15)
      within frame.find('li', text: dependent.full_name) do
        click_button 'Select'
      end
      assert_equal dependent.id.to_s, first("input[name='dependent_id']", visible: :all).value
      select 'Parent', from: 'relationship_type'
    end

    def fill_paper_form(first_name:, last_name:, email: nil)
      fill_in_applicant_information(first_name: first_name, last_name: last_name, email: email)
      fill_in_application_details
      fill_in_disability_information
      within_medical_provider_fieldset do
        paper_fill_in('Name', 'Dr. Evidence')
        paper_fill_in('Phone', '2025559876')
        paper_fill_in('Email', 'dr.evidence@example.com')
      end
      complete_paper_application_attestations
    end

    # Delegates to the shared helper so these flows exercise the same proof intake every other paper
    # system test does, then pins the starting state the round-trip assertions are measured against.
    def attach_proofs
      attach_and_accept_proofs
      sync_paper_submit_gate
      assert_filenames_survived
    end

    # Documents are the expensive thing to lose, but they are not the only one: staff retype the
    # whole applicant by hand, so a refusal that empties the form is the same defect in a cheaper
    # disguise.
    # The dependent fieldset carries inputs under the same `constituent[...]` names and is disabled
    # rather than removed, so these must select the enabled copy -- the one that will actually be
    # submitted. Scoping by fieldset instead silently reads the dependent form's empty fields and
    # reports lost data that was never lost.
    def assert_applicant_fields_survived(first_name:, last_name:)
      assert_equal first_name, applicant_field_value('first_name')
      assert_equal last_name, applicant_field_value('last_name')
      assert_predicate applicant_field_value('date_of_birth'), :present?
    end

    def applicant_field_value(field)
      find("input[name=\"constituent[#{field}]\"]:not([disabled])", visible: :all).value
    end

    # The point of the whole preflight: these must never be lost to a round trip.
    def assert_filenames_survived
      PROOFS.each do |field, fixture|
        selected = page.evaluate_script(
          "(document.querySelector('[name=\"#{field}\"]').files[0] || {}).name || ''"
        )
        assert_equal fixture, selected, "#{field} lost its selected document"
      end
    end

    # Native constraint validation silently refuses a submit, which otherwise shows up as a test
    # that "did nothing". Naming the offending fields turns that into a legible failure.
    def assert_no_invalid_fields
      invalid = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll('form :invalid'))
             .filter((field) => !field.disabled && field.type !== 'submit')
             .map((field) => {
               const v = field.validity;
               const why = ['valueMissing', 'typeMismatch', 'patternMismatch', 'rangeOverflow',
                            'rangeUnderflow', 'stepMismatch', 'tooLong', 'tooShort', 'badInput',
                            'customError'].filter((flag) => v[flag]);
               return [field.name || field.id, why.join(','), JSON.stringify(field.value || ''),
                       field.offsetParent === null ? 'hidden' : 'visible'].join(' ');
             })
      JS
      assert_empty invalid, "native validation is blocking submission:\n  #{invalid.join("\n  ")}"
    end

    def submit_and_settle
      assert_no_invalid_fields
      click_button 'Submit Paper Application'
      # The review is a network round trip, so settle before asserting.
      assert_no_selector '[data-paper-application-target="status"]', text: /Checking for existing/i, wait: 15
    end

    # A paper submission that persists nothing looks identical to one that was never sent. Reading
    # the rendered error back makes the difference visible instead of leaving a bare count mismatch.
    # Scoped to the flash region. A broader selector picks up the red "Rejected" proof-action
    # labels, which are ordinary form controls rather than errors.
    # Only the severities a refusal actually uses. Reading the whole flash region instead would count
    # "Paper application successfully submitted." as a refusal, and scoping by colour would pick up
    # the red "Rejected" proof-action labels, which are ordinary form controls.
    def server_refusal_text
      page.all('[data-testid="flash-alert"], [data-testid="flash-error"]', visible: :all)
          .map(&:text).compact_blank.join(' | ')
    end

    # A refusal and a silent non-write look identical from the browser, and the controller redirects
    # a failed create to the application it rolled back -- which then bounces to the index with
    # "not found", replacing the real error. So assert both: nothing refused, and we are actually
    # standing on the created application.
    def assert_created_without_refusal
      assert_equal '', server_refusal_text,
                   "the server refused the submission (at #{page.current_path})"
      assert_selector 'h1', text: 'Application #'
    end

    # Literally what the notice tells staff to do. A second tab rather than a same-tab navigation is
    # the whole point: navigating this tab is what would discard the four native file inputs, which
    # nothing can restore. The session cookie is shared across tabs, so signing in there is what
    # brings this tab back to life.
    def recover_session_in_another_tab
      other_tab = open_new_window
      within_window(other_tab) { system_test_sign_in(@admin) }
      other_tab.close
      switch_to_window(windows.first)
    end

    # Holds the review request open without failing it, so `checking` can be observed and so the
    # timeout has something to time out on. The real endpoint is left untouched; only the browser's
    # fetch is intercepted.
    def hold_identity_review_open
      page.execute_script(<<~JS)
        window.__originalFetch = window.fetch;
        window.__releaseIdentityReview = null;
        window.fetch = (url, options) => {
          if (!String(url).includes('identity_review')) return window.__originalFetch(url, options);
          return new Promise((resolve, reject) => {
            window.__releaseIdentityReview = () => resolve(window.__originalFetch(url, options));
            if (options && options.signal) {
              options.signal.addEventListener('abort', () => {
                const error = new Error('aborted');
                error.name = 'AbortError';
                reject(error);
              });
            }
          });
        };
      JS
    end

    def release_identity_review
      page.execute_script('if (window.__releaseIdentityReview) window.__releaseIdentityReview();')
      restore_identity_review
    end

    def stub_identity_review_failure
      page.execute_script(<<~JS)
        window.__originalFetch = window.fetch;
        window.fetch = (url, options) => String(url).includes('identity_review')
          ? Promise.reject(new Error('simulated network failure'))
          : window.__originalFetch(url, options);
      JS
    end

    def restore_identity_review
      page.execute_script('if (window.__originalFetch) window.fetch = window.__originalFetch;')
    end

    # Drives the real expiry path rather than waiting thirty minutes.
    def expire_open_review
      page.execute_script(<<~JS)
        const form = document.querySelector('form[data-controller~="paper-application"]');
        const controller = window.Stimulus.getControllerForElementAndIdentifier(form, 'paper-application');
        controller._identityReviewExpiresAt = Date.now() - 1000;
        controller._expireIdentityReview();
      JS
    end
  end
end
