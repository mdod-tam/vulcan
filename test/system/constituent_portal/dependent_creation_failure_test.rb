# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module ConstituentPortal
  # Visible evidence for the failed-creation re-render. Rollback restores the attempted dependent
  # to a new record while keeping the synthetic contact the guardian strategy wrote into it, so
  # re-rendering that object would put internal placeholders in front of the guardian and let an
  # unchanged retry store them as dependent-owned contact.
  class DependentCreationFailureTest < ApplicationSystemTestCase
    include SystemTestEvidence

    setup do
      @guardian = create(
        :constituent,
        first_name: 'Portal',
        last_name: 'Guardian',
        email: "portal-guardian-#{SecureRandom.hex(3)}@example.com",
        phone: '555-111-2222'
      )
      # A soft-match candidate, so creation reaches the review-case step that fails below.
      @existing = create(
        :constituent,
        first_name: 'Softmatch',
        last_name: 'Candidate',
        date_of_birth: Date.new(2010, 5, 15),
        email: "softmatch-#{SecureRandom.hex(3)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      @held_actions = []
      system_test_sign_in(@guardian)
    end

    teardown do
      Array(@held_actions).each do |controller_class, action|
        controller_class.class_eval do
          alias_method action, :"#{action}_without_hold"
          remove_method :"#{action}_without_hold"
        end
      end
    end

    # Visible evidence for the two admission outcomes. Both are states an ordinary guardian can
    # reach: the first by resubmitting a form the server already processed, the second by adding
    # someone they have already added.
    test 'a replayed submission reports the dependent as already added rather than an error' do
      visit new_constituent_portal_dependent_path
      fill_replay_form
      key = find('input[name="portal_creation_key"]', visible: :all).value
      click_button 'Add Dependent'
      assert_text 'Dependent was successfully created.'

      # A genuine second POST of the same request: identical body, and the key the first submission
      # carried. A guardian reaches this when the first response never lands and the browser or the
      # user resends. Selenium will not replay a request on its own, so the rendered form is set
      # back to that key rather than the fresh one this page was issued.
      visit new_constituent_portal_dependent_path
      fill_replay_form
      execute_script(
        "document.querySelector('input[name=\"portal_creation_key\"]').value = arguments[0]", key
      )
      click_button 'Add Dependent'

      assert_text 'was already added to your account'
      assert_equal 1, @guardian.reload.dependents.where(first_name: 'Replay').count,
                   'a replay must not create a second dependent'
      take_evidence_screenshot('dependent-create-replay-already-added', full: true, html: true)
    end

    # A reused key carrying changed input is a different operation, so it must refuse rather than
    # report success while discarding the change. Contact details are the sharp case: a guardian who
    # corrected an email and saw "already added" would reasonably believe it applied.
    test 'a reused key with changed input is refused as a stale form' do
      visit new_constituent_portal_dependent_path
      fill_replay_form
      key = find('input[name="portal_creation_key"]', visible: :all).value
      click_button 'Add Dependent'
      assert_text 'Dependent was successfully created.'

      visit new_constituent_portal_dependent_path
      fill_replay_form
      uncheck 'use_guardian_email_checkbox'
      fill_in 'Email', with: "changed-#{SecureRandom.hex(3)}@example.com"
      execute_script(
        "document.querySelector('input[name=\"portal_creation_key\"]').value = arguments[0]", key
      )
      click_button 'Add Dependent'

      assert_text 'This form was out of date'
      assert_equal 1, @guardian.reload.dependents.where(first_name: 'Replay').count
      take_evidence_screenshot('dependent-create-fingerprint-conflict', full: true, html: true)
    end

    # Asserting the data attribute proves only that the label was rendered. The state that matters is
    # the one the guardian actually sees, so this holds the response open, clicks without waiting,
    # and captures the control while it is genuinely disabled and reading its in-flight label.
    test 'the submit control shows its localized in-flight state while the request is open' do
      hold = held_creation_response

      visit new_constituent_portal_dependent_path
      fill_replay_form
      clicker = Thread.new { find('input[type=submit]').click }

      expected = I18n.t('constituent_portal.dependents.form.adding')
      assert_selector "input[type=submit][disabled][value='#{expected}']", wait: 5
      take_evidence_screenshot('dependent-create-submit-in-flight-label', full: true, html: true)
    ensure
      settle_click(clicker, hold)
    end

    test 'the edit form shows its localized in-flight state while the request is open' do
      dependent = create(:constituent, first_name: 'Editable', last_name: 'Dependent')
      GuardianRelationship.create!(guardian_user: @guardian, dependent_user: dependent,
                                   relationship_type: 'Parent')
      hold = held_update_response

      visit edit_constituent_portal_dependent_path(dependent)
      clicker = Thread.new { find('input[type=submit]').click }

      expected = I18n.t('constituent_portal.dependents.form.saving')
      assert_selector "input[type=submit][disabled][value='#{expected}']", wait: 5
      take_evidence_screenshot('dependent-edit-submit-in-flight-label', full: true, html: true)
    ensure
      settle_click(clicker, hold)
    end

    # No Spanish in-flight capture: the portal has no locale switching for signed-in users. I18n
    # locale is resolved only in public auth flows (ApplicationController#with_public_request_locale),
    # so a constituent with locale 'es' still renders in the default locale. The es translations
    # below are correct and consistent with the other constituent-facing keys, but nothing routes a
    # signed-in guardian to them today. Tracked in docs/future_work/mat_vulcan_todos.md under
    # "Signed-in portal locale routing" rather than asserted here.

    test 'adding a dependent the guardian already holds is refused with a route forward' do
      existing = create(:constituent, first_name: 'Repeat', last_name: 'Child',
                                      date_of_birth: Date.new(2013, 7, 4),
                                      email: "repeat-#{SecureRandom.hex(3)}@example.com",
                                      phone: "555-#{rand(100..999)}-#{rand(1000..9999)}")
      GuardianRelationship.create!(guardian_user: @guardian, dependent_user: existing,
                                   relationship_type: 'Parent')

      visit new_constituent_portal_dependent_path
      fill_in 'First Name', with: 'Repeat'
      fill_in 'Last Name', with: 'Child'
      fill_in 'Date of Birth', with: '07/04/2013'
      check 'Hearing'
      select 'Parent', from: 'Your Relationship to Dependent'
      check 'use_guardian_email_checkbox'
      check 'use_guardian_phone_checkbox'
      click_button 'Add Dependent'

      assert_text 'already associated with your account'
      assert_text 'contact the MAT Team'
      take_evidence_screenshot('dependent-create-duplicate-identity-refused', full: true, html: true)
    end

    test 'a failed dependent creation keeps the guardian contact choice and hides internal placeholders' do
      DuplicateReviewCases::CreateService.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'case creation failed', data: {})
      )

      visit new_constituent_portal_dependent_path
      fill_in 'First Name', with: @existing.first_name
      fill_in 'Last Name', with: @existing.last_name
      fill_in 'Date of Birth', with: '05/15/2010'
      check 'Hearing'
      select 'Parent', from: 'Your Relationship to Dependent'

      # Guardian contact strategy: leave dependent contact blank and use the guardian's own.
      check 'use_guardian_email_checkbox'
      check 'use_guardian_phone_checkbox'
      take_evidence_screenshot('dependent-create-guardian-contact-selected', full: true, html: true)

      click_button 'Add Dependent'

      assert_text(/failed to create dependent/i)

      # The guardian sees what they submitted, not the placeholders the attempt generated.
      assert_no_text '@system.matvulcan.local'
      assert_no_selector "input[value*='@system.matvulcan.local']"
      assert_no_selector "input[value^='000-']"
      assert find_by_id('use_guardian_email_checkbox').checked?,
             'the guardian email choice must survive the failed attempt'
      assert find_by_id('use_guardian_phone_checkbox').checked?,
             'the guardian phone choice must survive the failed attempt'
      take_evidence_screenshot('dependent-create-failure-preserves-guardian-contact', full: true, html: true)
    end

    # The harder case: the guardian types dependent contact and *then* chooses "use mine". The
    # portal form has no guardian-contact JS targets, so the typed values stay in the fields and
    # are submitted. Inferring the checkbox from contact blankness on the failed re-render would
    # flip both choices, and an unchanged retry would route this dependent's communications to the
    # dependent instead of the guardian.
    test 'a failed creation preserves the guardian choice even when dependent contact was typed first' do
      DuplicateReviewCases::CreateService.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'case creation failed', data: {})
      )

      visit new_constituent_portal_dependent_path
      fill_in 'First Name', with: @existing.first_name
      fill_in 'Last Name', with: @existing.last_name
      fill_in 'Date of Birth', with: '05/15/2010'
      check 'Hearing'
      select 'Parent', from: 'Your Relationship to Dependent'

      # Uncheck to reveal the dependent fields, type contact, then change your mind and use the
      # guardian's. The typed values stay in the (now hidden) fields and are still submitted.
      uncheck 'use_guardian_email_checkbox'
      uncheck 'use_guardian_phone_checkbox'
      fill_in 'Dependent Email', with: 'typed-first@example.com'
      fill_in 'Dependent Phone Number', with: '555-987-6543'
      check 'use_guardian_email_checkbox'
      check 'use_guardian_phone_checkbox'

      click_button 'Add Dependent'

      assert_text(/failed to create dependent/i)
      assert find_by_id('use_guardian_email_checkbox').checked?,
             'the guardian email choice must survive a failure even though contact was typed'
      assert find_by_id('use_guardian_phone_checkbox').checked?,
             'the guardian phone choice must survive a failure even though contact was typed'
      take_evidence_screenshot('dependent-create-failure-typed-contact-keeps-guardian-choice',
                               full: true, html: true)
    end

    private

    # Holds the server inside the action so the browser stays in its submitting state long enough to
    # observe and photograph. Released in an ensure block so a failure cannot wedge the suite.
    # Releases the held action and waits for the click thread to finish before returning, so
    # teardown cannot restore the aliased controller method while a request is still inside it --
    # which would either raise in that thread or leak the alias into the next test. #value re-raises
    # anything the thread hit, so a broken click surfaces instead of vanishing.
    def settle_click(clicker, hold)
      hold&.push(:go)
      clicker&.value
    end

    def held_creation_response
      hold_controller_action(ConstituentPortal::DependentsController, :create)
    end

    def held_update_response
      hold_controller_action(ConstituentPortal::DependentsController, :update)
    end

    def hold_controller_action(controller_class, action)
      gate = Queue.new
      controller_class.class_eval do
        alias_method :"#{action}_without_hold", action
        define_method(action) do
          gate.pop
          send(:"#{action}_without_hold")
        end
      end
      @held_actions << [controller_class, action]
      gate
    end

    def fill_replay_form
      fill_in 'First Name', with: 'Replay'
      fill_in 'Last Name', with: 'Dependent'
      fill_in 'Date of Birth', with: '04/02/2014'
      check 'Hearing'
      select 'Parent', from: 'Your Relationship to Dependent'
      check 'use_guardian_email_checkbox'
      check 'use_guardian_phone_checkbox'
    end
  end
end
