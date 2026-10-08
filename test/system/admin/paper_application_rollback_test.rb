# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'
require_relative '../../support/paper_application_context_helpers'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  # Retry scenarios preserve submitted decisions and verify the durable outcome after files are replaced.
  # Force the failure at the attachment boundary to test the response with valid form input.
  class PaperApplicationRollbackTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper
    include PaperApplicationContextHelpers
    include SystemTestEvidence

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
    end

    test 'a rolled-back create keeps every typed value and can be retried to success' do
      # This scenario uses the force-reveal helper. Other scenarios use real controls because direct visibility changes
      # can mask Stimulus failures.
      reveal_adult_application_sections
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      fill_paper_form
      assert_no_difference ['User.count', 'Application.count'] do
        click_button 'Submit Paper Application'
        assert_text(/rejected by storage/i, wait: 15)
      end

      assert_no_text(/not found/i)
      assert_no_match(%r{/admin/applications}, page.current_path)
      assert_no_text(/Proof upload failed/i)

      assert_typed_values_survived
      assert_file_inputs_empty

      take_evidence_screenshot('paper-application-rollback-retry', full: true, html: true)

      # Replace files without the shared accept-all helper, which would overwrite the restored ID rejection.
      ProofAttachmentService.unstub(:attach_proof)
      reattach_files_required_by_restored_dispositions
      sync_paper_submit_gate

      assert_button 'Submit Paper Application', disabled: false, wait: 10
      take_evidence_screenshot('paper-application-rollback-submit-ready', full: true, html: true)

      assert_restored_dispositions

      assert_difference ['User.count', 'Application.count'], 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end

      assert_durable_outcome_matches_restored_dispositions
      take_evidence_screenshot('paper-application-rollback-retry-succeeded', full: true, html: true)
    end

    # A callback failure after commit must route to the existing application to avoid duplicate submissions.
    test 'a post-commit failure lands on the real application with a warning, not a retry form' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')

      choose_adult_branch_through_the_ui
      fill_paper_form

      assert_difference ['User.count', 'Application.count'], 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end

      assert_text(/successfully submitted/i)
      assert_text(/follow-up step did not finish/i)
      assert_no_selector "form[action='#{admin_paper_applications_path}']"
      assert_equal 1, Application.where(user: Users::Constituent.find_by(first_name: 'Rollback')).count

      take_evidence_screenshot('paper-application-post-commit-warning', full: true, html: true)
    end

    # Use real controls to exercise Stimulus.
    # Hidden companions submit 0 for unchecked guardian-contact choices.
    test 'a failed dependent submission restores its branch, guardian, and contact choices' do
      guardian = create(:constituent, first_name: 'Dependent', last_name: 'Guardian')
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      select_guardian_through_the_ui(guardian)
      fill_dependent_details
      fill_in_application_details(household_size: 3, annual_income: 25_000)
      fill_in_disability_information
      attach_and_accept_proofs
      # The income flag exists only after the proof sections render.
      choose_no_information_flags
      complete_paper_application_attestations

      assert_no_difference ['User.count', 'Application.count'] do
        click_button 'Submit Paper Application'
        assert_text(/rejected by storage/i, wait: 20)
      end

      assert_dependent_branch_restored(guardian)
      assert_file_inputs_empty
      # Native inputs are empty, but valid signed uploads remain available. Replace uploads without changing other
      # decisions.
      take_evidence_screenshot('paper-application-rollback-dependent', full: true, html: true)

      ProofAttachmentService.unstub(:attach_proof)
      reattach_files_required_by_restored_dispositions
      attach_file 'id_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
      sync_paper_submit_gate
      assert_button 'Submit Paper Application', disabled: false, wait: 10

      assert_difference ['User.count', 'Application.count'], 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end

      dependent = Application.order(:id).last.user
      assert_equal 'Dependent', dependent.first_name
      assert_equal 'Child', dependent.last_name
      assert_equal guardian.id, Application.order(:id).last.managing_guardian_id,
                   'the restored guardian selection must be the one that ends up managing it'
      take_evidence_screenshot('paper-application-rollback-dependent-succeeded', full: true, html: true)
    end

    # Submitted corrections must survive the adult picker refresh on retry.
    test 'a retry keeps corrections to a selected existing adult rather than the on-file values' do
      existing = create(:constituent, first_name: 'OnFile', last_name: 'Applicant',
                                      phone: '202-555-0101')
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      select_existing_adult_through_the_ui(existing)
      corrected_phone = '202-555-0199'
      find('input[name="constituent[phone]"]:not([disabled])').set(corrected_phone)
      verify_existing_adult_contact
      fill_in_application_details(household_size: 2, annual_income: 20_000)
      fill_in_disability_information
      fill_in_medical_provider_information
      attach_and_accept_proofs
      complete_paper_application_attestations

      assert_no_difference ['User.count', 'Application.count'] do
        click_button 'Submit Paper Application'
        assert_text(/rejected by storage/i, wait: 20)
      end

      # Wait for the context fetch before asserting that the submitted correction survived.
      assert_selector '[data-adult-picker-target="onFileSummary"]', visible: true, wait: 15
      assert_equal corrected_phone, enabled_field('constituent[phone]').value,
                   'the correction was overwritten by the on-file value'
      assert_equal existing.id.to_s, first("input[name='existing_constituent_id']", visible: :all).value

      within '[data-adult-picker-target="selectedPane"]' do
        assert_text existing.full_name
      end

      # The retry guidance must be visible to sighted staff as well as announced by the live region.
      assert_text(/entries were restored/i)
      assert_text(/Income proof/i)

      take_evidence_screenshot('paper-application-rollback-existing-adult', full: true, html: true)

      ProofAttachmentService.unstub(:attach_proof)
      verify_existing_adult_contact
      reattach_files_required_by_restored_dispositions
      attach_file 'id_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
      sync_paper_submit_gate
      assert_button 'Submit Paper Application', disabled: false, wait: 10

      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end

      assert_equal existing.id, Application.order(:id).last.user_id,
                   'the retry must attach to the selected existing applicant, not a new one'
      take_evidence_screenshot('paper-application-rollback-existing-adult-succeeded', full: true, html: true)
    end

    # A replacement selection must restore automatic field values from the new adult record.
    test 'changing the selection after a failed retry autopopulates the replacement adult' do
      original = create(:constituent, first_name: 'OnFile', last_name: 'Applicant', phone: '202-555-0101')
      replacement = create(:constituent, first_name: 'Replacement', last_name: 'Adult',
                                         phone: '202-555-0123')
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      select_existing_adult_through_the_ui(original)
      verify_existing_adult_contact
      fill_in_application_details(household_size: 2, annual_income: 20_000)
      fill_in_disability_information
      fill_in_medical_provider_information
      attach_and_accept_proofs
      complete_paper_application_attestations

      assert_no_difference ['User.count', 'Application.count'] do
        click_button 'Submit Paper Application'
        assert_text(/rejected by storage/i, wait: 20)
      end
      assert_selector '[data-adult-picker-target="onFileSummary"]', visible: true, wait: 15

      click_button 'Change Selection'
      select_existing_adult_through_the_ui(replacement)

      assert_equal 'Replacement', enabled_field('constituent[first_name]').value,
                   'the replacement adult was not autopopulated'
      assert_equal replacement.id.to_s, first("input[name='existing_constituent_id']", visible: :all).value
      take_evidence_screenshot('paper-application-rollback-changed-selection', full: true, html: true)
    end

    # The application page could return not found after an unverified write. Route to the list with the duplicate
    # warning.
    test 'an unconfirmed write lands on the applications list with the warning and no success notice' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      Application.stubs(:exists?).raises(ActiveRecord::ConnectionNotEstablished, 'database went away')

      choose_adult_branch_through_the_ui
      fill_paper_form
      choose 'reject_id_proof', allow_label_click: true
      select 'None Provided', from: 'id_proof_rejection_reason'
      sync_paper_submit_gate

      click_button 'Submit Paper Application'

      assert_current_path admin_applications_path, ignore_query: true, wait: 20
      assert_text(/could not be confirmed/i)
      assert_text(/could create a duplicate/i)
      assert_no_text(/successfully submitted/i)
      assert_no_text(/not found/i)
      take_evidence_screenshot('paper-application-unconfirmed-write', full: true, html: true)
    end

    # Verify on-file identity before submission as well as after failure. The policy applies on both renders.
    test 'selecting an existing dependent shows on-file identity before any submission' do
      guardian = create(:constituent, first_name: 'Initial', last_name: 'Guardian')
      # Use a long name to test the card at narrow width.
      dependent = create(:constituent, first_name: 'Aleksandra-Wilhelmina',
                                       last_name: 'Oyelaran-Fitzgerald',
                                       date_of_birth: Date.new(2012, 9, 14))
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: dependent,
                                   relationship_type: 'Parent')

      select_guardian_through_the_ui(guardian)
      select_existing_dependent_through_the_ui(dependent)

      assert_text(/Existing dependent selected/i)
      assert_text(/Aleksandra-Wilhelmina Oyelaran-Fitzgerald/)
      assert_text(/will not change them/i)
      assert_text(/contact the MAT support team/i)
      assert_no_selector '#dependent_constituent_first_name', visible: :all
      assert_no_selector '#dependent_constituent_date_of_birth', visible: :all

      assert_selector "input[name='constituent[dependent_email]']", visible: :all

      take_evidence_screenshot('paper-application-existing-dependent-initial-selection',
                               full: true, html: true)

      # WCAG 1.4.10 uses 320 CSS pixels for reflow, equivalent to a 1280px viewport at 400% zoom.
      # A phone-width capture or 200% text enlargement does not prove this boundary.
      original_size = page.current_window.size
      begin
        page.current_window.resize_to(320, 900)
        assert_text(/Existing dependent selected/i)
        assert_text(/Aleksandra-Wilhelmina Oyelaran-Fitzgerald/)
        # This assertion covers the summary card, not full-page WCAG conformance.
        # Reported guardian-section overflow remains a separate follow-up: 364px section width and 60px document
        # overflow at 320px.
        # Measure both the outer box and its contents because a contained box can still have overflowing descendants.
        card = evaluate_script(<<~JS)
          (() => {
            const el = document.getElementById('existing-dependent-summary');
            if (!el) return null;
            const r = el.getBoundingClientRect();
            return {
              inner_overflow: el.scrollWidth - el.clientWidth,
              right: Math.round(r.right),
              left: Math.round(r.left),
              viewport: document.documentElement.clientWidth
            };
          })()
        JS
        assert_not_nil card, 'the summary card must be present to measure'
        assert card['inner_overflow'] <= 1,
               "the summary card's contents overflow it at 320px by #{card['inner_overflow']}px"
        assert card['right'] <= card['viewport'] + 1 && card['left'] >= -1,
               "the summary card escapes the 320px viewport (left #{card['left']}, right #{card['right']})"
        take_evidence_screenshot('paper-application-existing-dependent-reflow-320',
                                 full: true, html: true)
      ensure
        page.current_window.resize_to(original_size[0], original_size[1])
      end

      # Exercise Change Dependent because clearSelection would also clear the guardian. Scope the action to the
      # dependent card.
      within '#dependent-info-section' do
        click_button 'Change Dependent'
      end

      assert_no_text(/Existing dependent selected/i, wait: 10)
      assert_equal guardian.id.to_s, first("input[name='guardian_id']", visible: :all).value,
                   'changing the dependent must not clear the guardian'
      assert_equal '', first("input[name='dependent_id']", visible: :all).value

      assert_selector '#dependent_constituent_first_name', wait: 10
      assert_text(/New Dependent Information/i)

      # Turbo removes the clicked button. Move focus to the on-file chooser so staff can select another dependent
      # without creating a duplicate.
      landed = evaluate_script(<<~JS)
        (() => {
          const a = document.activeElement;
          if (!a || a === document.body) return 'body';
          const frame = document.getElementById('guardian_dependents');
          if (frame && frame.contains(a)) return 'dependents-list';
          if (a.id === 'dependent_constituent_first_name') return 'new-dependent-first-name';
          return a.tagName + '#' + (a.id || '');
        })()
      JS
      # This guardian has an on-file list, so only that focus destination satisfies the assertion.
      assert_equal 'dependents-list', landed,
                   "focus went to #{landed} instead of the on-file dependent list"
    end

    test 'an existing-dependent retry shows on-file identity and keeps editable contact' do
      guardian = create(:constituent, first_name: 'Existing', last_name: 'Guardian')
      dependent = create(:constituent, first_name: 'Jonathan', last_name: 'Smith',
                                       date_of_birth: Date.new(2011, 4, 3))
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: dependent,
                                   relationship_type: 'Parent')
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      select_guardian_through_the_ui(guardian)
      select_existing_dependent_through_the_ui(dependent)
      fill_in_application_details(household_size: 2, annual_income: 20_000)
      fill_in_disability_information
      fill_in_medical_provider_information
      attach_and_accept_proofs
      complete_paper_application_attestations

      sync_paper_submit_gate
      assert_no_difference ['User.count', 'Application.count'] do
        click_button 'Submit Paper Application'
        assert_text(/rejected by storage/i, wait: 20)
      end

      assert_text(/Existing dependent selected/i)
      assert_text(/Jonathan Smith/)
      assert_text(/will not change them/i)
      assert_text(/contact the MAT support team/i)
      assert_no_selector '#dependent_constituent_first_name', visible: :all
      assert_no_selector '#dependent_constituent_date_of_birth', visible: :all
      assert_equal dependent.id.to_s, first("input[name='dependent_id']", visible: :all).value

      assert_file_inputs_empty
      take_evidence_screenshot('paper-application-rollback-existing-dependent', full: true, html: true)

      # Retry and initial selection nest the dependent frame differently. Exercise the action on both renders to expose
      # an incorrect controller binding.
      within '#dependent-info-section' do
        click_button 'Change Dependent'
      end
      assert_no_text(/Existing dependent selected/i, wait: 10)
      assert_equal guardian.id.to_s, first("input[name='guardian_id']", visible: :all).value,
                   'changing the dependent on a retry must not clear the guardian'
      assert_equal '', first("input[name='dependent_id']", visible: :all).value

      # Verify focus on this render too because the frame has different nesting.
      retry_focus = evaluate_script(<<~JS)
        (() => {
          const a = document.activeElement;
          if (!a || a === document.body) return 'body';
          const frame = document.getElementById('guardian_dependents');
          if (frame && frame.contains(a)) return 'dependents-list';
          if (a.id === 'dependent_constituent_first_name') return 'new-dependent-first-name';
          return a.tagName + '#' + (a.id || '');
        })()
      JS
      assert_equal 'dependents-list', retry_focus,
                   "focus went to #{retry_focus} instead of the on-file dependent list on retry"

      # Reselect the same dependent for the rest of the scenario.
      select_existing_dependent_through_the_ui(dependent)
      assert_text(/Existing dependent selected/i, wait: 10)

      # The common sections must stay within the form controller to render on retry.
      # A misplaced ERB end can hide them and resemble a Stimulus timing failure.
      assert_selector '[data-applicant-type-target="commonSections"]', visible: true, wait: 10
      assert_file_inputs_empty

      ProofAttachmentService.unstub(:attach_proof)
      reattach_files_required_by_restored_dispositions
      attach_file 'id_proof', Rails.root.join('test/fixtures/files/residency_proof.pdf')
      sync_paper_submit_gate
      assert_button 'Submit Paper Application', disabled: false, wait: 10

      assert_difference 'Application.count', 1 do
        assert_no_difference 'User.count' do
          click_button 'Submit Paper Application'
          assert_selector 'h1', text: 'Application #', wait: 20
        end
      end

      application = Application.order(:id).last
      assert_equal dependent.id, application.user_id, 'the retry must attach to the selected dependent'
      assert_equal 'Jonathan', dependent.reload.first_name
      assert_equal Date.new(2011, 4, 3), dependent.date_of_birth
      take_evidence_screenshot('paper-application-rollback-existing-dependent-succeeded', full: true, html: true)
    end

    private

    # Use real controls so Stimulus owns section visibility and enabled state.
    def choose_adult_branch_through_the_ui
      choose 'An Adult (applying for themselves)', allow_label_click: true
      click_button 'Create New Applicant'
      assert_selector '#self-info-section', text: "Applicant's Information", wait: 10
    end

    def select_existing_dependent_through_the_ui(dependent)
      within '[data-guardian-picker-target="dependentsFrame"]' do
        click_button 'Select', match: :first, wait: 15
      end
      assert_selector '#dependent-info-section', wait: 10
      assert_equal dependent.id.to_s, first("input[name='dependent_id']", visible: :all).value
      # The form requires a relationship choice even for an existing relationship.
      select 'Parent', from: 'relationship_type'
    end

    def select_guardian_through_the_ui(guardian)
      choose 'A Dependent (minor or adult requiring guardian)', allow_label_click: true
      within 'fieldset', text: 'Guardian Information' do
        fill_in 'guardian_search_q', with: guardian.full_name
      end
      within '#guardian_search_results' do
        find('li', text: /#{Regexp.escape(guardian.full_name)}/i, wait: 10).click
      end
      within 'fieldset', text: 'Guardian Information' do
        assert_selector "input[name='guardian_id'][value='#{guardian.id}']", visible: :all, wait: 10
      end
    end

    def fill_dependent_details
      assert_selector '#dependent-info-section', wait: 10
      within '#dependent-info-section' do
        paper_fill_in 'First Name', 'Dependent'
        paper_fill_in 'Last Name', 'Child'
        find('input[name="constituent[date_of_birth]"]:not([disabled])').set('01/15/2010')
        # Uncheck guardian contact to require dependent contact. Hidden companions submit 0 for these unchecked choices.
        uncheck 'use_guardian_email' if has_checked_field?('use_guardian_email', wait: 2)
        uncheck 'use_guardian_phone' if has_checked_field?('use_guardian_phone', wait: 2)
        # A restored guardian-address choice could change the destination for documents.
        uncheck 'use_guardian_address_checkbox' if has_checked_field?('use_guardian_address_checkbox', wait: 2)
        find('input[name="constituent[dependent_email]"]:not([disabled])').set('dependent.child@example.com')
        find('input[name="constituent[dependent_phone]"]:not([disabled])').set('202-555-0177')
        assert_equal 'dependent.child@example.com',
                     find('input[name="constituent[dependent_email]"]:not([disabled])').value,
                     'the dependent email did not take before submitting'
      end
      select 'Parent', from: 'relationship_type'
    end

    # Separate dynamic controllers own these flags.
    def choose_no_information_flags
      check 'no_medical_provider_information', allow_label_click: true
      check 'no_income_information', allow_label_click: true
    end

    def assert_dependent_branch_restored(guardian)
      assert_text(/rejected by storage/i)
      # Locked applicant-type radios remain checked but disabled. An enabled-only selector would miss the restored
      # choice.
      assert first("input[name='applicant_type'][value='dependent']", visible: :all).checked?,
             'the dependent branch was not restored'
      assert_not first("input[name='applicant_type'][value='self']", visible: :all).checked?,
                 'the adult branch must not be selected on a dependent retry'
      assert_equal guardian.id.to_s,
                   first("input[name='guardian_id']", visible: :all).value,
                   'the selected guardian was not restored'
      assert_selector '[data-guardian-picker-target="selectedGuardianDisplay"]',
                      text: guardian.full_name, wait: 10

      assert_equal 'Dependent', enabled_field('constituent[first_name]').value
      assert_equal 'Child', enabled_field('constituent[last_name]').value
      assert_equal 'dependent.child@example.com', enabled_field('constituent[dependent_email]').value,
                   "the dependent's own email was not restored"

      assert_not enabled_checkbox('use_guardian_email').checked?,
                 'an unchecked guardian-email choice must stay unchecked'
      assert_not enabled_checkbox('use_guardian_phone').checked?,
                 'an unchecked guardian-phone choice must stay unchecked'
      assert_not first("input[type='checkbox'][name='use_guardian_address']", visible: :all).checked?,
                 'an unchecked guardian-address choice must stay unchecked'

      assert enabled_checkbox('no_medical_provider_information').checked?,
             'the no-provider flag was not restored'
      assert enabled_checkbox('no_income_information').checked?,
             'the no-income flag was not restored'
      assert_equal 'Parent', first("select[name='relationship_type']", visible: :all).value,
                   'the guardian relationship was not restored'
    end

    def fill_paper_form
      fill_in_applicant_information(first_name: 'Rollback', last_name: 'Retry')
      fill_in_application_details(household_size: 2, annual_income: 20_000)
      fill_in_disability_information
      fill_in_medical_provider_information
      attach_and_accept_proofs
      choose_non_default_proof_dispositions
      complete_paper_application_attestations
    end

    # Use non-default medical and ID actions so defaults cannot mask lost state.
    def choose_non_default_proof_dispositions
      choose 'upload_only_medical_certification', allow_label_click: true
      choose 'reject_id_proof', allow_label_click: true
      select 'None Provided', from: 'id_proof_rejection_reason'
      sync_paper_submit_gate
    end

    # Select enabled inputs at page scope. The disabled dependent fieldset retains controls with the same names.
    def assert_typed_values_survived
      {
        'constituent[first_name]' => 'Rollback',
        'constituent[last_name]' => 'Retry',
        'application[household_size]' => '2',
        'application[medical_provider_name]' => 'Dr. Smith'
      }.each do |name, expected|
        assert_equal expected, enabled_field(name).value, "#{name} was not restored"
      end

      # Compare currency as a number to detect data loss independently of display formatting.
      assert_equal 20_000,
                   enabled_field('application[annual_income]').value.to_s.gsub(/[^\d.]/, '').to_f.to_i,
                   'annual income was not restored'

      %w[application[maryland_resident] applicant_attributes[self_certify_disability]
         application[medical_release_authorized] application[terms_accepted]
         applicant_attributes[hearing_disability]].each do |name|
        assert enabled_checkbox(name).checked?, "#{name} was not restored"
      end

      # Workflow decisions are not model attributes, so they require explicit restoration.
      { 'income_proof_action' => 'accept', 'residency_proof_action' => 'accept',
        'id_proof_action' => 'reject', 'medical_certification_action' => 'upload_only' }.each do |group, expected|
        assert_equal expected, checked_value(group), "#{group} was not restored"
      end

      assert_equal 'none_provided',
                   first('select[name="id_proof_rejection_reason"]', visible: :all).value,
                   'the rejection reason was not restored'
    end

    # The restored ID rejection specifies None Provided. An ID attachment would contradict it.
    def reattach_files_required_by_restored_dispositions
      { 'medical_certification' => 'medical_certification_valid.pdf',
        'income_proof' => 'income_proof.pdf',
        'residency_proof' => 'residency_proof.pdf' }.each do |field, fixture|
        attach_file field, Rails.root.join("test/fixtures/files/#{fixture}")
      end
    end

    def assert_restored_dispositions
      { 'income_proof_action' => 'accept', 'residency_proof_action' => 'accept',
        'id_proof_action' => 'reject', 'medical_certification_action' => 'upload_only' }.each do |group, expected|
        assert_equal expected, checked_value(group), "#{group} changed before the retry was submitted"
      end
      assert_equal 'none_provided',
                   first('select[name="id_proof_rejection_reason"]', visible: :all).value,
                   'the rejection reason changed before the retry was submitted'
    end

    def assert_durable_outcome_matches_restored_dispositions
      application = Application.order(:id).last
      assert_equal 'Rollback', application.user.first_name
      assert_equal 2, application.household_size

      assert application.income_proof.attached?, 'income proof should have been attached'
      assert application.residency_proof.attached?, 'residency proof should have been attached'
      assert_equal 'approved', application.income_proof_status
      assert_equal 'approved', application.residency_proof_status

      assert application.medical_certification.attached?, 'the certification should have been attached'

      assert_not application.id_proof.attached?, 'a rejected ID proof must not carry a document'
      assert_equal 'rejected', application.id_proof_status

      review = application.proof_reviews.find_by(proof_type: :id)
      assert_not_nil review, 'the ID rejection should have been recorded as a proof review'
      assert_equal 'rejected', review.status
      # Assert both the reason code and displayed text. Presence alone cannot detect a substituted rejection reason.
      assert_equal 'none_provided', review.rejection_reason_code,
                   'the durable rejection code must be the one that was restored on the form'
      assert_equal 'No ID proof was provided with the application.', review.rejection_reason,
                   'the durable rejection text must match the restored selection'
    end

    def checked_value(group)
      page.evaluate_script("document.querySelector('input[name=\"#{group}\"]:checked')?.value || ''")
    end

    # Native controls remain empty while signed uploads display their saved filenames.
    def assert_file_inputs_empty
      PROOFS.each_key do |field|
        selected = page.evaluate_script(
          "(document.querySelector('input[type=file][name=\"#{field}\"]')?.files?.[0] || {}).name || ''"
        )
        assert_equal '', selected, "#{field} unexpectedly still holds a file"
      end
    end

    def enabled_field(name)
      first("[name=\"#{name}\"]:not([disabled])", visible: :all)
    end

    # Rails adds a hidden 0 input with the checkbox name. Select the checkbox explicitly to avoid its companion.
    def enabled_checkbox(name)
      first("input[type='checkbox'][name=\"#{name}\"]:not([disabled])", visible: :all)
    end
  end
end
