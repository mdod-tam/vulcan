# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'
require_relative '../../support/paper_application_context_helpers'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  # What staff can actually do after a paper create fails and the whole transaction rolls back.
  #
  # "Usable retry form" is a claim about finishing the job without redoing it, so this test finishes
  # it that way: it asserts every submitted non-file value came back, reselects only the files the
  # restored dispositions actually require, changes nothing else, and checks the durable result
  # matches the decisions staff originally made.
  #
  # Two earlier versions proved less than they appeared to. One asserted two names and stopped, while
  # most of the form was being dropped. The next reattached through the shared accept-everything
  # helper, which silently overwrote the restored ID rejection -- proving staff could re-enter their
  # decisions, which is the opposite of the contract.
  #
  # The failure is forced at the proof-attachment boundary rather than by mangling the form, because
  # the subject is the response, not the cause.
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
      # The only scenario that uses the force-reveal helper. The others drive the real controls,
      # because that helper sets visibility and disabled state directly and would mask the Stimulus
      # behaviour those captures exist to prove.
      reveal_adult_application_sections
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      fill_paper_form
      assert_no_difference ['User.count', 'Application.count'] do
        click_button 'Submit Paper Application'
        assert_text(/rejected by storage/i, wait: 15)
      end

      # A failure must not navigate to an application the rollback removed. This *is* reachable: the
      # service classifies by querying the database, and a rolled-back create has nothing to find.
      assert_no_text(/not found/i)
      assert_no_match(%r{/admin/applications}, page.current_path)
      # The internal step name must not trail the real reason.
      assert_no_text(/Proof upload failed/i)

      assert_typed_values_survived
      assert_file_inputs_empty

      take_evidence_screenshot('paper-application-rollback-retry', full: true, html: true)

      # Finish the job by touching *only* the file inputs. Deliberately not the shared
      # attach-and-accept helper: that re-chooses "Accept & Upload" for every proof, which would
      # overwrite the restored ID rejection and make this test prove staff can re-enter their
      # decisions rather than that they never had to.
      ProofAttachmentService.unstub(:attach_proof)
      reattach_files_required_by_restored_dispositions
      sync_paper_submit_gate

      # Readiness is the whole promise: files back, nothing else touched, Submit live again.
      assert_button 'Submit Paper Application', disabled: false, wait: 10
      take_evidence_screenshot('paper-application-rollback-submit-ready', full: true, html: true)

      # The dispositions must still be exactly what was restored, immediately before submitting.
      assert_restored_dispositions

      assert_difference ['User.count', 'Application.count'], 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end

      assert_durable_outcome_matches_restored_dispositions
      take_evidence_screenshot('paper-application-rollback-retry-succeeded', full: true, html: true)
    end

    # The opposite outcome, and the one the removed branch used to cover by accident. A post-commit
    # callback failure leaves the application committed, so the admin must be sent to it -- being
    # handed a retry form here is how a duplicate gets created.
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

    # The branch that restored nothing at all. Driven through the real radio, search and picker so
    # the Stimulus reveal/enable behaviour is part of what the capture proves.
    #
    # The contact choices are deliberately non-default -- guardian email and phone unchecked, the
    # dependent's own values typed in. A browser omits unchecked checkboxes entirely, which is the
    # case a controller test posting an explicit "0" cannot reproduce.
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
      # After the proof sections exist: the income flag lives inside one of them.
      choose_no_information_flags
      complete_paper_application_attestations

      assert_no_difference ['User.count', 'Application.count'] do
        click_button 'Submit Paper Application'
        assert_text(/rejected by storage/i, wait: 20)
      end

      assert_dependent_branch_restored(guardian)
      assert_file_inputs_empty
      # Submit is gated here, and correctly so: the files are the one thing a server render cannot
      # put back. Readiness is proved below, after reselecting them and changing nothing else.
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

    # The picker refetches the selected adult on connect and pastes the on-file record over the
    # fields. On a retry the submitted values are newer -- here, a corrected phone number staff came
    # to the paper form to make -- so the database original must not win.
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

      # The context fetch has to have visibly finished, or this asserts against a form the picker
      # simply has not reached yet.
      assert_selector '[data-adult-picker-target="onFileSummary"]', visible: true, wait: 15
      assert_equal corrected_phone, enabled_field('constituent[phone]').value,
                   'the correction was overwritten by the on-file value'
      assert_equal existing.id.to_s, first("input[name='existing_constituent_id']", visible: :all).value

      # The card must name who is selected, not merely report that someone is. Only the click path
      # used to fill it, so a restored retry showed an empty green "selected applicant" box.
      within '[data-adult-picker-target="selectedPane"]' do
        assert_text existing.full_name
      end

      # Files are the one thing a retry cannot put back, and the submit button goes disabled with no
      # visible reason on a form this long. The sr-only live region is not enough for sighted staff.
      assert_text(/documents need reattaching/i)
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

    # The suppression is scoped to the restored selection. Replacing that selection means the newer
    # answer is the *new* adult's on-file record, so autopopulation has to come back -- otherwise
    # staff get a selected applicant whose name, date of birth and contact fields are all blank.
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

    # When the write cannot be verified, staff must not be sent to the record's own page: if the row
    # is not there, "application not found" replaces the very guidance telling them to check before
    # entering it again. The list is somewhere they can act on either way.
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

    # The policy applies from the moment a dependent is selected, not only after a failure, so the
    # ordinary path needs its own browser proof. Without this, the only evidence would be a retry
    # screen, and a reader could reasonably conclude read-only was a failure-mode behaviour.
    test 'selecting an existing dependent shows on-file identity before any submission' do
      guardian = create(:constituent, first_name: 'Initial', last_name: 'Guardian')
      # Deliberately long but entirely plausible, so the same capture answers both the long-name and
      # the narrow-width question rather than needing a viewport matrix.
      dependent = create(:constituent, first_name: 'Aleksandra-Wilhelmina',
                                       last_name: 'Oyelaran-Fitzgerald',
                                       date_of_birth: Date.new(2012, 9, 14))
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: dependent,
                                   relationship_type: 'Parent')

      select_guardian_through_the_ui(guardian)
      select_existing_dependent_through_the_ui(dependent)

      # No submission has happened: this is the plain selection state.
      assert_text(/Existing dependent selected/i)
      assert_text(/Aleksandra-Wilhelmina Oyelaran-Fitzgerald/)
      assert_text(/will not change them/i)
      assert_text(/contact the MAT support team/i)
      assert_no_selector '#dependent_constituent_first_name', visible: :all
      assert_no_selector '#dependent_constituent_date_of_birth', visible: :all

      # Contact stays editable -- the writer does persist that.
      assert_selector "input[name='constituent[dependent_email]']", visible: :all

      take_evidence_screenshot('paper-application-existing-dependent-initial-selection',
                               full: true, html: true)

      # 320 CSS pixels: WCAG 1.4.10 Reflow's reference width, equivalent to 400% zoom from a 1280px
      # viewport. A 375-390px phone capture is useful mobile evidence but is not this claim, and a
      # 200% text check answers enlargement rather than reflow.
      original_size = page.current_window.size
      begin
        page.current_window.resize_to(320, 900)
        assert_text(/Existing dependent selected/i)
        assert_text(/Aleksandra-Wilhelmina Oyelaran-Fitzgerald/)
        # Deliberately NOT a page-level WCAG claim. 1.4.10 conformance applies to a complete page,
        # and this page still fails: measured at 320px, `#guardian-info-section` is 364px wide, so
        # the document overflows by 60px. That is untouched guardian markup, tracked separately.
        # What is asserted here is narrower and is this PR's to own -- the summary card introduces
        # no overflow of its own.
        #
        # Scoped to the card itself rather than `#dependent-info-section`, which wraps a great deal
        # of unchanged form. Both checks matter: the bounding rectangle proves the outer box fits in
        # the viewport, while scrollWidth proves no descendant spills out of it -- an outer box can
        # sit inside the viewport while its contents overflow.
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

      # Pressed, not merely present. Asserting the action attribute proves only that a name was
      # typed into the markup; it cannot show what that name does. The picker's own control calls
      # `clearSelection`, which would also drop the guardian -- from a button whose copy promises
      # only to change the dependent.
      # Scoped to the card, and named distinctly from the guardian card's own "Change Selection".
      within '#dependent-info-section' do
        click_button 'Change Dependent'
      end

      assert_no_text(/Existing dependent selected/i, wait: 10)
      assert_equal guardian.id.to_s, first("input[name='guardian_id']", visible: :all).value,
                   'changing the dependent must not clear the guardian'
      assert_equal '', first("input[name='dependent_id']", visible: :all).value

      # And the path forward is genuinely usable: the blank new-dependent form is back.
      assert_selector '#dependent_constituent_first_name', wait: 10
      assert_text(/New Dependent Information/i)

      # Turbo destroyed the clicked button, so focus must land somewhere deliberate rather than
      # falling back to <body> and stranding a keyboard user at the top of a very long form.
      #
      # The destination is the on-file dependent list, not the blank name field: "Change Dependent"
      # usually means "wrong person, pick the right one", and the card just dismissed warns against
      # creating a duplicate to work around a bad record.
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
      # This guardian has an on-file dependent list, so that is where focus belongs. The
      # new-dependent field is only the fallback when no list exists, and accepting either here
      # would let the intended destination regress unnoticed.
      assert_equal 'dependents-list', landed,
                   "focus went to #{landed} instead of the on-file dependent list"
    end

    # The branch where identity is on-file fact rather than paper-intake input. Also the browser
    # proof of that decision: the fields must not be editable, and no hidden copy may be submitted.
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

      # Identity is stated, not offered for editing, and nothing hidden carries it back.
      assert_text(/Existing dependent selected/i)
      assert_text(/Jonathan Smith/)
      assert_text(/will not change them/i)
      assert_text(/contact the MAT support team/i)
      assert_no_selector '#dependent_constituent_first_name', visible: :all
      assert_no_selector '#dependent_constituent_date_of_birth', visible: :all
      assert_equal dependent.id.to_s, first("input[name='dependent_id']", visible: :all).value

      assert_file_inputs_empty
      take_evidence_screenshot('paper-application-rollback-existing-dependent', full: true, html: true)

      # The same control, exercised on the *other* production render. This frame is nested inside
      # the guardian-picker element here and outside it on initial selection, so an action bound to
      # guardian-picker worked on this path and silently did nothing on that one. Both paths are
      # driven because one passing path proved nothing about the other.
      within '#dependent-info-section' do
        click_button 'Change Dependent'
      end
      assert_no_text(/Existing dependent selected/i, wait: 10)
      assert_equal guardian.id.to_s, first("input[name='guardian_id']", visible: :all).value,
                   'changing the dependent on a retry must not clear the guardian'
      assert_equal '', first("input[name='dependent_id']", visible: :all).value

      # Focus asserted here too. This frame is nested differently on this render, and focus after a
      # Turbo swap is exactly the kind of behaviour that can hold on one path and not the other.
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

      # Put the dependent back so the rest of the scenario continues against the same record.
      select_existing_dependent_through_the_ui(dependent)
      assert_text(/Existing dependent selected/i, wait: 10)

      # The common sections -- application details, disability, proofs, attestations -- must come
      # back with the rest of the form, because a retry that cannot reach them cannot be submitted.
      # This regressed once while the read-only identity block was being added: a misplaced `<% end %>`
      # closed the form before `commonSections`, so the target rendered outside the element its
      # controller owns and stayed hidden no matter how long the test waited. Asserted here because
      # the symptom looks like a controller timing bug and is actually unbalanced markup.
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
      # The read-only contract, proved durably: paper intake does not touch identity.
      assert_equal 'Jonathan', dependent.reload.first_name
      assert_equal Date.new(2011, 4, 3), dependent.date_of_birth
      take_evidence_screenshot('paper-application-rollback-existing-dependent-succeeded', full: true, html: true)
    end

    private

    # Real controls only: the applicant-type radio and the "Create New Applicant" button, letting
    # Stimulus reveal and enable the sections itself.
    def choose_adult_branch_through_the_ui
      choose 'An Adult (applying for themselves)', allow_label_click: true
      click_button 'Create New Applicant'
      assert_selector '#self-info-section', text: "Applicant's Information", wait: 10
    end

    def select_existing_adult_through_the_ui(applicant)
      choose 'An Adult (applying for themselves)', allow_label_click: true
      fill_in 'adult_search_q', with: applicant.full_name
      within '#adult_search_results' do
        find('li', text: /#{Regexp.escape(applicant.full_name)}/i, wait: 10).click
      end
      assert_selector '[data-adult-picker-target="onFileSummary"]', visible: true, wait: 15
    end

    # Submit gating requires the admin to confirm they checked the on-file contact details against
    # the paper form; it is part of the existing-adult contract rather than incidental setup.
    def verify_existing_adult_contact
      box = first('[data-adult-picker-target="verificationCheckbox"]', visible: :all)
      return if box.nil? || box.checked?

      box.click
    end

    def select_existing_dependent_through_the_ui(dependent)
      within '[data-guardian-picker-target="dependentsFrame"]' do
        click_button 'Select', match: :first, wait: 15
      end
      assert_selector '#dependent-info-section', wait: 10
      assert_equal dependent.id.to_s, first("input[name='dependent_id']", visible: :all).value
      # Required, and not prefilled from the existing relationship.
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
        # Away from the defaults: unchecking these is what makes the dependent's own contact fields
        # required, and a browser omits the unchecked boxes from the submission entirely.
        uncheck 'use_guardian_email' if has_checked_field?('use_guardian_email', wait: 2)
        uncheck 'use_guardian_phone' if has_checked_field?('use_guardian_phone', wait: 2)
        # Address too: it has the same absent-when-unchecked problem, and silently flipping
        # "same address as guardian" back on after a failure changes where documents are sent.
        uncheck 'use_guardian_address_checkbox' if has_checked_field?('use_guardian_address_checkbox', wait: 2)
        find('input[name="constituent[dependent_email]"]:not([disabled])').set('dependent.child@example.com')
        find('input[name="constituent[dependent_phone]"]:not([disabled])').set('202-555-0177')
        assert_equal 'dependent.child@example.com',
                     find('input[name="constituent[dependent_email]"]:not([disabled])').value,
                     'the dependent email did not take before submitting'
      end
      select 'Parent', from: 'relationship_type'
    end

    # Two flags driven by separate dynamic controllers; one scenario exercises both.
    def choose_no_information_flags
      check 'no_medical_provider_information', allow_label_click: true
      check 'no_income_information', allow_label_click: true
    end

    def assert_dependent_branch_restored(guardian)
      assert_text(/rejected by storage/i)
      # Checked, not enabled: the applicant-type radios are deliberately disabled once a branch is
      # locked in, so filtering on :not([disabled]) would find nothing and report a loss that is not
      # happening.
      assert first("input[name='applicant_type'][value='dependent']", visible: :all).checked?,
             'the dependent branch was not restored'
      assert_not first("input[name='applicant_type'][value='self']", visible: :all).checked?,
                 'the adult branch must not be selected on a dependent retry'
      assert_equal guardian.id.to_s,
                   first("input[name='guardian_id']", visible: :all).value,
                   'the selected guardian was not restored'
      # A hidden id is not a restored selection as far as staff are concerned: the panel has to say
      # which guardian it means.
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

    # Deliberately away from the defaults. Medical especially: "approved" is what a fresh form
    # selects, so leaving it there would let a total failure to restore look like success. The ID
    # proof is rejected with a reason, which is the state that was silently dropped entirely.
    def choose_non_default_proof_dispositions
      choose 'upload_only_medical_certification', allow_label_click: true
      choose 'reject_id_proof', allow_label_click: true
      select 'None Provided', from: 'id_proof_rejection_reason'
      sync_paper_submit_gate
    end

    # Everything the server is capable of restoring. Selected on the *enabled* input at page scope:
    # the dependent fieldset carries inputs under the same names and is disabled rather than removed,
    # so scoping by fieldset reads its empty fields and reports losses that never happened.
    def assert_typed_values_survived
      {
        'constituent[first_name]' => 'Rollback',
        'constituent[last_name]' => 'Retry',
        'application[household_size]' => '2',
        'application[medical_provider_name]' => 'Dr. Smith'
      }.each do |name, expected|
        assert_equal expected, enabled_field(name).value, "#{name} was not restored"
      end

      # Compared as a number: the field is currency-formatted, so its exact string is a display
      # concern and asserting it would break on formatting rather than on data loss.
      assert_equal 20_000,
                   enabled_field('application[annual_income]').value.to_s.gsub(/[^\d.]/, '').to_f.to_i,
                   'annual income was not restored'

      %w[application[maryland_resident] applicant_attributes[self_certify_disability]
         application[medical_release_authorized] application[terms_accepted]
         applicant_attributes[hearing_disability]].each do |name|
        assert enabled_checkbox(name).checked?, "#{name} was not restored"
      end

      # Workflow instructions, not attributes of any record, so nothing carries them back on its
      # own. All four groups, including the two moved off their defaults.
      { 'income_proof_action' => 'accept', 'residency_proof_action' => 'accept',
        'id_proof_action' => 'reject', 'medical_certification_action' => 'upload_only' }.each do |group, expected|
        assert_equal expected, checked_value(group), "#{group} was not restored"
      end

      assert_equal 'none_provided',
                   first('select[name="id_proof_rejection_reason"]', visible: :all).value,
                   'the rejection reason was not restored'
    end

    # Files only, and only where the restored disposition needs one. ID is restored as a rejection
    # for "None Provided", so attaching an ID document would contradict the decision being retried.
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

    # The point of the whole exercise: the decisions staff made the first time are the decisions the
    # database ends up with, without their having re-entered any of them.
    def assert_durable_outcome_matches_restored_dispositions
      application = Application.order(:id).last
      assert_equal 'Rollback', application.user.first_name
      assert_equal 2, application.household_size

      assert application.income_proof.attached?, 'income proof should have been attached'
      assert application.residency_proof.attached?, 'residency proof should have been attached'
      assert_equal 'approved', application.income_proof_status
      assert_equal 'approved', application.residency_proof_status

      assert application.medical_certification.attached?, 'the certification should have been attached'

      # The restored rejection has to survive all the way to durable state, document and all.
      assert_not application.id_proof.attached?, 'a rejected ID proof must not carry a document'
      assert_equal 'rejected', application.id_proof_status

      review = application.proof_reviews.find_by(proof_type: :id)
      assert_not_nil review, 'the ID rejection should have been recorded as a proof review'
      assert_equal 'rejected', review.status
      # The exact reason staff picked, not merely that some reason was stored: a restore that
      # substituted a different reason would still be present, and would still be wrong.
      # Both halves of the stored reason, exactly. A restore that substituted a different reason
      # would still be present and still be wrong, so presence alone proves nothing. The code is the
      # selection staff made; the text is what anyone reading the application later will see.
      assert_equal 'none_provided', review.rejection_reason_code,
                   'the durable rejection code must be the one that was restored on the form'
      assert_equal 'No ID proof was provided with the application.', review.rejection_reason,
                   'the durable rejection text must match the restored selection'
    end

    def checked_value(group)
      page.evaluate_script("document.querySelector('input[name=\"#{group}\"]:checked')?.value || ''")
    end

    # Stated rather than papered over: a server render cannot repopulate a native file input, so the
    # documents genuinely must be reselected. The test pins that this is the *only* thing lost.
    def assert_file_inputs_empty
      PROOFS.each_key do |field|
        selected = page.evaluate_script(
          "(document.querySelector('[name=\"#{field}\"]')?.files?.[0] || {}).name || ''"
        )
        assert_equal '', selected, "#{field} unexpectedly still holds a file"
      end
    end

    def enabled_field(name)
      first("[name=\"#{name}\"]:not([disabled])", visible: :all)
    end

    # Rails renders a hidden "0" companion immediately before each check box, under the same name.
    # Matching on name alone finds that hidden input, which is never checked -- so the assertion
    # fails while the real control is restored perfectly.
    def enabled_checkbox(name)
      first("input[type='checkbox'][name=\"#{name}\"]:not([disabled])", visible: :all)
    end
  end
end
