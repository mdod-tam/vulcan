# frozen_string_literal: true

require 'application_system_test_case'

module Evaluators
  class EvaluationWorkflowTest < ApplicationSystemTestCase
    include EvaluatorSystemAssertions

    include EvaluationSystemTestSetup

    test 'follow-up dashboard and list lead to the cancelled appointment recovery form' do
      cancelled = create(:evaluation, evaluator: @evaluator, status: :cancelled)
      unrelated = create(:evaluation, status: :no_show)
      cancelled.constituent.update!(first_name: 'Followup', last_name: 'Applicant')
      unrelated.constituent.update!(first_name: 'Unrelated', last_name: 'Applicant')
      badge_selector = ".#{ApplicationController.helpers.badge_class_for(:evaluation, cancelled.status).split.join('.')}"
      visit evaluators_dashboard_path

      assert_selector '#followup-evaluations-section', text: cancelled.constituent.full_name
      assert_no_selector '#followup-evaluations-section', text: unrelated.constituent.full_name
      within('#followup-evaluations-section tbody tr', text: cancelled.constituent.full_name) do
        assert_selector "span#{badge_selector}"
      end
      followup_link = find("#followup-evaluations-section a[href='#{evaluators_evaluation_path(cancelled)}']")
      assert followup_link['aria-label'].start_with?(followup_link.text)
      take_screenshot('evaluator-followup-dashboard', html: true, full: true)
      click_link 'View follow up'

      assert_selector '#evaluations-list-heading', text: 'Evaluations Needing Follow-up'
      assert_selector 'tbody', text: cancelled.constituent.full_name
      assert_no_selector 'tbody', text: unrelated.constituent.full_name
      within('tbody tr', text: cancelled.constituent.full_name) do
        assert_selector "span#{badge_selector}"
      end
      take_screenshot('evaluator-followup-list', html: true, full: true)
      find("tbody a[href='#{evaluators_evaluation_path(cancelled)}']").click

      assert_selector '#reschedule-evaluation-form'
      assert_no_selector '#complete-evaluation-form'
      take_screenshot('evaluator-followup-recovery', html: true, full: true)
    end

    test 'dashboard shortcuts use matching labels and focus their own section headings' do
      @evaluator.update!(first_name: 'Jordan', last_name: 'Evaluator')
      requested = create(:evaluation, evaluator: @evaluator, status: :requested, evaluation_date: nil)
      followup = create(:evaluation, evaluator: @evaluator, status: :cancelled)
      completed = create(:evaluation, :completed, evaluator: @evaluator)
      { @evaluation => 'Scheduled', requested => 'Requested', followup => 'Followup', completed => 'Completed' }.each do |evaluation, name|
        evaluation.constituent.update!(first_name: name, last_name: 'Applicant')
      end
      visit evaluators_dashboard_path
      {
        'needs-scheduling-section' => requested,
        'upcoming-evaluations-section' => @evaluation,
        'followup-evaluations-section' => followup
      }.each do |section, evaluation|
        within("##{section} tbody tr", text: evaluation.constituent.full_name) do
          assert_text "Evaluator: #{@evaluator.full_name}"
        end
      end
      within('.space-y-4 > div', text: completed.constituent.full_name) do
        assert_text "Evaluator: #{@evaluator.full_name}"
      end
      within('#needs-scheduling-section tbody tr', text: requested.constituent.full_name) do
        assert_selector 'span', text: 'Needs Scheduling'
        assert_selector "span.#{ApplicationController.helpers.badge_class_for(:evaluation, requested.status).split.join('.')}"
      end
      page.execute_script('window.evaluatorShortcutDocument = "same-document"')
      {
        'View requested' => 'needs-scheduling-heading',
        'View scheduled' => 'upcoming-evaluations-heading',
        'View completed' => 'recent-completed-heading'
      }.each do |text, heading|
        assert_selector "a[href='##{heading}']", text: text
        page.execute_script("document.querySelector('a[href=\"##{heading}\"]').focus()")
        page.driver.browser.keyboard.type(:enter)
        assert_selector "h2##{heading}:focus"
        assert_equal heading, page.evaluate_script('document.activeElement.id')
        assert_equal 'same-document', page.evaluate_script('window.evaluatorShortcutDocument')
      end
      take_screenshot('evaluator-dashboard-shortcut-focused', html: true, full: true)

      admin = create(:admin, first_name: 'Avery', last_name: 'Administrator')
      assigned = create(:evaluation, evaluator: admin, status: :scheduled)
      assigned.constituent.update!(first_name: 'Admin', last_name: 'Applicant')
      click_button 'Sign Out'
      system_test_sign_in(admin, bypass_mfa_enrollment: true)
      install_stimulus_error_reporting
      visit evaluators_dashboard_path
      link = find("a[href='#my-upcoming-evaluations-table-heading']")
      assert link['aria-label'].start_with?(link.text)
      assert_selector '#my-upcoming-evaluations-section', text: assigned.constituent.full_name
      within('#my-upcoming-evaluations-section tbody tr', text: assigned.constituent.full_name) do
        assert_text "Evaluator: #{admin.full_name}"
      end
      within('#upcoming-evaluations-section tbody tr', text: @evaluation.constituent.full_name) do
        assert_text "Evaluator: #{@evaluator.full_name}"
        assert_no_text "Evaluator: #{admin.full_name}"
      end
      page.execute_script('document.querySelector("a[href=\"#my-upcoming-evaluations-table-heading\"]").focus()')
      page.driver.browser.keyboard.type(:enter)
      assert_selector 'h2#my-upcoming-evaluations-table-heading:focus'
      assert_equal 'my-upcoming-evaluations-table-heading', page.evaluate_script('document.activeElement.id')
      take_screenshot('admin-my-scheduled-shortcut-focused', html: true, full: true)
      page.current_window.resize_to(375, 812)
      take_screenshot('admin-dashboard-evaluator-names-narrow', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 900)
    end

    test 'stale cancellation and rescheduling forms retain one focused rejection after report completion' do
      { cancel: 'Cancel Evaluation', reschedule: 'Reschedule Evaluation' }.each do |action, button|
        evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled)
        visit evaluators_evaluation_path(evaluation)
        form_id = "#{action}-evaluation-form"
        within "##{form_id}" do
          if action == :cancel
            fill_in 'Cancellation Reason', with: 'Stale cancellation request'
          else
            fill_in 'Reason for Rescheduling', with: 'Stale rescheduling request'
          end
        end
        evaluation.update!(status: :completed, appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)
        within "##{form_id}" do
          click_button button
        end

        assert_single_action_error("#{action}-errors")
        assert_selector "##{action}-errors:focus"
        assert_no_selector "##{action}-errors a"
        assert_no_selector "##{form_id}"
        assert_selector '#supplemental-notes-form'
        assert_equal 'completed', evaluation.reload.status
        take_screenshot("evaluator-completed-#{action}-rejected", html: true, full: true)
      end
    end

    test 'cancellation and rolled-back no-show notes remain editable after rejection' do
      @evaluation.update!(evaluation_date: 1.hour.ago)
      visit evaluators_evaluation_path(@evaluation)

      within '#cancel-evaluation-form' do
        fill_in 'Cancellation Reason', with: ' '
        click_button 'Cancel Evaluation'
      end
      assert_text 'Failed to cancel evaluation:'
      assert_single_action_error('cancel-errors')
      within '#cancel-evaluation-form' do
        assert_field 'Cancellation Reason', with: ' '
      end
      take_screenshot('evaluator-cancel-restored', html: true, full: true)

      within '#cancel-evaluation-form' do
        fill_in 'Cancellation Reason', with: 'Contact person declined the appointment'
        click_button 'Cancel Evaluation'
      end
      assert_text 'Evaluation cancelled successfully.'
      assert_equal 'cancelled', @evaluation.reload.status
      assert_equal 'Contact person declined the appointment', @evaluation.notes
      take_screenshot('evaluator-cancel-recorded', html: true, full: true)

      missed = create(:evaluation, evaluator: @evaluator, status: :scheduled)
      missed.update!(evaluation_date: 1.hour.ago)
      visit evaluators_evaluation_path(missed)

      failed_event = Event.new
      failed_event.errors.add(:base, 'Audit record unavailable')
      AuditEventService.stub(:log, ->(**) { raise ActiveRecord::RecordInvalid, failed_event }) do
        within '#no-show-evaluation-form' do
          fill_in 'No-Show Notes (optional)', with: 'Reached voicemail'
          click_button 'Mark as No-Show'
        end
        assert_text 'Failed to mark evaluation as no-show:'
        assert_single_action_error('no-show-errors')
      end
      assert_equal 'scheduled', missed.reload.status
      within '#no-show-evaluation-form' do
        assert_field 'No-Show Notes (optional)', with: 'Reached voicemail'
      end
      take_screenshot('evaluator-no-show-restored', html: true, full: true)

      within '#no-show-evaluation-form' do
        fill_in 'No-Show Notes (optional)', with: ''
        click_button 'Mark as No-Show'
      end
      assert_text 'Evaluation marked as no-show.'
      assert_equal 'no_show', missed.reload.status
      assert_nil missed.notes
      assert_selector '#reschedule-evaluation-form'
      take_screenshot('evaluator-no-show-recorded', html: true, full: true)
    end

    test 'assigned evaluator opens scoped guardian contact information on desktop and narrow screens' do
      first_guardian = create(:constituent)
      guardian = create(:constituent, locale: 'es', phone_type: 'text', preferred_means_of_communication: 'ASL')
      applicant = create(:constituent, email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
                                       dependent_email: guardian.email, phone: '000-123-4567', dependent_phone: guardian.phone)
      create(:guardian_relationship, guardian_user: first_guardian, dependent_user: applicant)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: applicant)
      application = create(:application, user: applicant, managing_guardian: guardian, status: :approved,
                                         application_date: Date.current)
      evaluation = create(:evaluation, application: application, constituent: applicant, evaluator: @evaluator)
      page.current_window.resize_to(1200, 900)
      visit evaluators_evaluation_path(evaluation)
      click_link I18n.t('application_contact.link')

      assert_selector 'h1', text: I18n.t('application_contact.title')
      assert_text applicant.full_name
      assert_text guardian.full_name
      assert_selector "a[href='mailto:#{guardian.email}']"
      assert_selector "a[href='tel:#{guardian.phone}']"
      assert_no_text first_guardian.email
      assert_no_text '@system.matvulcan.local'
      assert_no_text '000-123-4567'
      assert_no_text 'Annual Income'
      assert_no_text 'Certifying Professional'
      assert_no_selector "a[href='#{admin_application_path(application)}']"
      take_screenshot('evaluator-assessment-desktop', html: true, full: true)

      page.current_window.resize_to(375, 812)
      assert_selector 'h1', text: I18n.t('application_contact.title')
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=,
                      page.evaluate_script('window.innerWidth')
      take_screenshot('evaluator-assessment-narrow', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 900)
    end

    test 'admin transfers the existing appointment and former evaluator loses access' do
      application = create(:application, status: :approved, application_date: Date.current, fulfillment_type: :equipment)
      evaluation = create(:evaluation, application: application, constituent: application.user, evaluator: @evaluator)
      replacement = create(:evaluator)
      admin = create(:admin)
      original_date = evaluation.evaluation_date
      original_notes = evaluation.notes
      click_button 'Sign Out'
      system_test_sign_in(admin, bypass_mfa_enrollment: true)
      browser = page.driver.browser
      browser.disable_javascript
      visit admin_application_path(application)
      assert_text 'Enable JavaScript to confirm evaluator reassignment.'
      within "[data-testid='evaluator-assignment-section']" do
        click_button 'Reassign Evaluator'
      end
      assert_current_path admin_application_path(application)
      assert_no_selector '#evaluator-reassign-confirm-dialog[open]'
      assert_equal @evaluator.id, evaluation.reload.evaluator_id
      assert_equal 0, Event.where(action: 'evaluator_reassigned', auditable: evaluation).count
      browser.page.command('Emulation.setScriptExecutionDisabled', value: false)
      page.refresh

      within "[data-testid='evaluator-assignment-section']" do
        click_button 'Reassign Evaluator'
      end
      assert_selector '#evaluator-reassign-confirm-dialog[open]'
      assert_equal 'Cancel', page.evaluate_script('document.activeElement.textContent.trim()')
      within '#evaluator-reassign-confirm-dialog' do
        select "#{replacement.full_name} (#{replacement.email})", from: 'New evaluator (required)'
        click_button 'Cancel'
      end
      assert_no_selector '#evaluator-reassign-confirm-dialog[open]'
      assert_equal 'Reassign Evaluator', page.evaluate_script('document.activeElement.textContent.trim()')
      assert_equal @evaluator.id, evaluation.reload.evaluator_id
      assert_equal 0, Event.where(action: 'evaluator_reassigned', auditable: evaluation).count
      within "[data-testid='evaluator-assignment-section']" do
        click_button 'Reassign Evaluator'
      end
      page.driver.browser.keyboard.type(:escape)
      assert_no_selector '#evaluator-reassign-confirm-dialog[open]'
      assert_equal 'Reassign Evaluator', page.evaluate_script('document.activeElement.textContent.trim()')
      assert_equal @evaluator.id, evaluation.reload.evaluator_id
      within "[data-testid='evaluator-assignment-section']" do
        click_button 'Reassign Evaluator'
      end
      within '#evaluator-reassign-confirm-dialog' do
        select "#{replacement.full_name} (#{replacement.email})", from: 'New evaluator (required)'
      end
      page.current_window.resize_to(375, 812)
      dialog_geometry = page.evaluate_script(<<~JS)
        (() => {
          const dialog = document.getElementById('evaluator-reassign-confirm-dialog');
          const bounds = dialog.getBoundingClientRect();
          return { left: bounds.left, right: bounds.right,
                   clientWidth: dialog.clientWidth, scrollWidth: dialog.scrollWidth };
        })()
      JS
      assert_operator dialog_geometry['left'], :>=, 0
      assert_operator dialog_geometry['right'], :<=, 375
      assert_operator dialog_geometry['scrollWidth'], :<=, dialog_geometry['clientWidth']
      take_screenshot('admin-evaluator-reassignment', html: true, full: true)
      within '#evaluator-reassign-confirm-dialog' do
        click_button 'Confirm reassignment'
      end
      page.current_window.resize_to(1200, 900)
      assert_text 'Evaluator reassigned. Existing appointment details have been preserved.'
      assert_equal replacement.id, evaluation.reload.evaluator_id
      assert_equal original_date, evaluation.evaluation_date
      assert_equal original_notes, evaluation.notes
      assert_equal 1, Event.where(action: 'evaluator_reassigned', auditable: evaluation).count
      take_screenshot('admin-evaluator-reassigned', html: true, full: true)

      click_button 'Sign Out'
      system_test_sign_in(@evaluator, bypass_mfa_enrollment: true)
      visit application_details_evaluators_evaluation_path(evaluation)
      assert_text 'Evaluation not found.'
      assert_no_text application.user.email
      assert_no_selector '#assessment-contact-heading'
      take_screenshot('former-evaluator-assessment-denied', html: true, full: true)

      click_button 'Sign Out'
      system_test_sign_in(replacement, bypass_mfa_enrollment: true)
      visit application_details_evaluators_evaluation_path(evaluation)
      assert_selector 'h1', text: I18n.t('application_contact.title')
      assert_text application.user.full_name
      take_screenshot('replacement-evaluator-assessment', html: true, full: true)
    ensure
      browser&.page&.command('Emulation.setScriptExecutionDisabled', value: false)
      page.current_window.resize_to(1200, 900)
    end
  end
end
