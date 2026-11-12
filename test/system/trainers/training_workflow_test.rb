# frozen_string_literal: true

require 'application_system_test_case'

module Trainers
  class TrainingWorkflowTest < ApplicationSystemTestCase
    include TrainingSystemTestSetup

    test 'guardian coordinating contact and requested cancellation remain usable at a narrow viewport' do
      manager = create(:constituent, first_name: 'Sam', last_name: 'Guardian', locale: 'es',
                                     physical_address_1: 'Managing Guardian Avenue')
      create(:guardian_relationship, guardian_user: manager, dependent_user: @constituent)
      Current.set(user: manager) do
        @constituent.update!(email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local", dependent_email: manager.email)
      end
      @application.update!(managing_guardian: manager)
      page.current_window.resize_to(375, 812)
      visit trainers_training_session_path(@session)
      assert_text manager.email
      assert_text 'Managing Guardian Avenue'
      assert_no_link 'View Application', href: admin_application_path(@application)
      assert_field 'schedule_scheduled_for', with: ''
      find('summary', text: 'Cancel this unscheduled appointment').click
      select 'Constituent', from: 'cancel_cancellation_initiator'
      fill_in 'cancel_cancellation_reason', with: '   '
      accept_confirm { click_button 'Cancel this unscheduled appointment' }
      assert_action_error('cancel')
      assert_selector :select, 'cancel_cancellation_initiator', selected: 'Constituent'
      assert_field 'cancel_cancellation_reason', with: '   '
      fill_in 'cancel_cancellation_reason', with: 'The managing guardian declined this unscheduled appointment.'
      assert_selector 'details[open] input[type=submit][value="Cancel this unscheduled appointment"]:not([disabled])'
      take_screenshot('trainer-guardian-requested-cancel-narrow', html: true, full: true)
      accept_confirm { click_button 'Cancel this unscheduled appointment' }

      assert_text 'Training session cancelled successfully.'
      assert @session.reload.status_cancelled?
      assert_equal @trainer.id, @application.reload.assigned_trainer_id
      assert_equal 'constituent', @session.cancellation_initiator
      assert_field 'follow_up_scheduled_for', with: ''
      assert_field 'follow_up_reschedule_reason', with: ''
      assert_no_horizontal_overflow
      take_screenshot('trainer-requested-cancelled-follow-up-blank', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 900)
    end

    test 'Spanish long-duration confirmation permits editing before validation and a corrected report' do
      page.current_window.resize_to(375, 900)
      @trainer.update!(locale: 'es')
      @session.update!(status: :scheduled, scheduled_for: 1.day.from_now.change(sec: 0))
      visit trainers_training_session_path(@session, locale: 'es')
      assert_selector 'h2#session-actions-heading', text: '¿Qué ocurrió?'
      assert_selector '[data-training-outcome-target="status"]:empty', visible: :all
      find_by_id('training-outcome').click
      select 'Completar capacitación', from: 'training-outcome'
      assert_selector '#training-outcome:focus'
      assert_selector '[data-training-outcome-target="status"]',
                      text: 'Se muestra el formulario de «Completar capacitación». Complete los datos y guarde los cambios.'
      take_screenshot('trainer-spanish-completion-revealed-accessible-feedback', html: true, full: true)
      future_time = 1.hour.from_now.strftime('%Y-%m-%dT%H:%M')
      fill_in 'complete_completed_at', with: future_time
      select @product.name, from: 'complete_product_trained_on_id'
      fill_in 'complete_duration_hours', with: '3'
      fill_in 'complete_constituent_summary', with: 'Practicamos los subtítulos durante una visita prolongada.'
      select 'español', from: 'complete_summary_locale'
      fill_in 'complete_internal_notes', with: 'Observaciones privadas para el personal.'
      observe_native_submission
      click_button 'Guardar informe completado'
      assert_selector 'dialog[open]', text: '¿Confirma 3 horas?'
      assert_selector '[data-training-duration-confirmation-target=noButton]:focus'
      assert page.evaluate_script("document.querySelector('dialog[open]').scrollWidth <= document.querySelector('dialog[open]').clientWidth")
      take_screenshot('trainer-spanish-long-duration-confirmation', html: true, full: true)
      page.driver.browser.keyboard.type(:enter)
      assert_no_selector 'dialog[open]'
      assert_selector '#complete_duration_hours:focus'
      assert_field 'complete_duration_hours', with: '3'
      assert_equal [], page.evaluate_script('window.trainingSubmissions')
      assert_equal 0, Event.where(auditable: @session, action: 'training_completed').count

      fill_in 'complete_duration_hours', with: '2.75'
      click_button 'Guardar informe completado'
      assert_selector 'dialog[open]', text: '¿Confirma 2.75 horas?'
      within('dialog[open]') { find('[data-training-duration-confirmation-target=yesButton]').click }
      assert_action_error('complete', heading: 'Corrija los siguientes errores')
      assert_selector '[data-training-outcome-target="status"]:empty', visible: :all
      assert_native_submission(I18n.t('trainer_workflow.forms.saving_report', locale: :es), submitter_id: 'complete_submit')
      assert_field 'complete_completed_at', with: future_time
      assert_field 'complete_duration_hours', with: '2.75'
      assert_field 'complete_constituent_summary', with: 'Practicamos los subtítulos durante una visita prolongada.'
      assert_field 'complete_internal_notes', with: 'Observaciones privadas para el personal.'
      take_screenshot('trainer-spanish-confirmed-report-restored-error', html: true, full: true)

      fill_in 'complete_completed_at', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
      observe_native_submission
      click_button 'Guardar informe completado'
      assert_selector 'dialog[open]', text: '¿Confirma 2.75 horas?'
      within('dialog[open]') { find('[data-training-duration-confirmation-target=yesButton]').click }
      assert_text 'La sesión de capacitación se marcó como completada correctamente.'
      assert_selector '[data-testid="flash-notice"][role="status"][aria-live="polite"]',
                      text: 'La sesión de capacitación se marcó como completada correctamente.'
      assert @session.reload.status_completed?
      assert_equal BigDecimal('2.75'), @session.duration_hours
      assert_equal 'es', @session.summary_locale
      assert_native_submission(I18n.t('trainer_workflow.forms.saving_report', locale: :es), submitter_id: 'complete_submit')
      assert_equal 1, Event.where(auditable: @session, action: 'training_completed').count
      take_screenshot('trainer-spanish-confirmed-long-report-completed', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 900)
    end

    test 'reschedule and no-show outcome retries retain their own editable reasons and blank next agreement' do
      @session.update!(status: :scheduled, scheduled_for: 30.minutes.from_now.change(sec: 0), location: 'Original library')
      visit trainers_training_session_path(@session)
      select 'Reschedule at constituent request', from: 'training-outcome'
      assert_field 'reschedule_scheduled_for', with: ''
      fill_in 'reschedule_scheduled_for', with: @session.scheduled_for.strftime('%Y-%m-%dT%H:%M')
      fill_in 'reschedule_location', with: ''
      fill_in 'reschedule_reschedule_reason', with: 'Guardian requested a different agreed date.'
      click_button 'Reschedule at constituent request'

      assert_action_error('reschedule')
      assert_field 'reschedule_location', with: ''
      assert_field 'reschedule_reschedule_reason', with: 'Guardian requested a different agreed date.'
      take_screenshot('trainer-reschedule-unchanged-date-restored', html: true, full: true)
      agreed_time = 1.hour.from_now.change(sec: 0)
      fill_in 'reschedule_scheduled_for', with: agreed_time.strftime('%Y-%m-%dT%H:%M')
      fill_in 'reschedule_location', with: 'New library'
      click_button 'Reschedule at constituent request'
      assert_text 'Training session rescheduled successfully.'
      assert_equal agreed_time, @session.reload.scheduled_for
      assert_equal 'New library', @session.location

      travel_to(agreed_time + 1.hour) do
        switch_user(@trainer, bypass_mfa_enrollment: true)
        visit trainers_training_session_path(@session)
        select 'Record no-show', from: 'training-outcome'
        fill_in 'no_show_no_show_notes', with: '   '
        click_button 'Record no-show'
        assert_action_error('no_show')
        assert_field 'no_show_no_show_notes', with: '   '
        assert_selector :select, 'training-outcome', selected: 'Record no-show'
        take_screenshot('trainer-no-show-reason-restored', html: true, full: true)
        fill_in 'no_show_no_show_notes', with: 'The agreed appointment elapsed without attendance.'
        click_button 'Record no-show'
        assert_text 'Training session marked as no-show.'
        assert @session.reload.status_no_show?
        assert_field 'follow_up_scheduled_for', with: ''
        assert_field 'follow_up_reschedule_reason', with: ''
        take_screenshot('trainer-no-show-recorded-next-agreement-blank', html: true, full: true)
      end
    end

    test 'admin retains quota-slot and between-appointment removal while a guardian reads a newly submitted demo summary' do
      admin = create(:admin)
      Policy.find_or_create_by!(key: 'max_training_sessions').update!(value: 3)
      create_list(:training_session, 2, :completed, application: @application, trainer: @trainer, product_trained_on: @product)
      switch_user(admin, bypass_mfa_enrollment: true)
      visit admin_application_path(@application)
      within 'section[aria-labelledby="admin-training-heading"]' do
        assert_text '2 completed, 1 reserved, 0 remaining of 3'
        assert_link 'View Details'
        assert_button 'Unassign Trainer'
      end
      take_screenshot('admin-final-reserved-slot-view-and-remove', html: true, full: true)
      accept_confirm { click_button 'Unassign Trainer' }
      assert_text 'Trainer assignment removed.'
      assert_nil @application.reload.assigned_trainer_id
      assert @session.reload.status_cancelled?
      assert_equal 2, @application.training_sessions.completed_sessions.count

      manager = create(:constituent, first_name: 'Riley', last_name: 'Guardian', locale: 'es')
      dependent = create(:constituent, email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local", dependent_email: manager.email)
      create(:guardian_relationship, guardian_user: manager, dependent_user: dependent)
      managed = create(:application, :approved, :with_all_proofs, user: dependent, managing_guardian: manager,
                                                                  assigned_trainer: @trainer, application_date: Date.current)
      create_list(:training_session, 2, :completed, application: managed, trainer: @trainer, product_trained_on: @product)
      requested = create(:training_session, :scheduled, application: managed, trainer: @trainer)
      switch_user(@trainer, bypass_mfa_enrollment: true)
      visit trainers_training_session_path(requested)
      select 'Complete training', from: 'training-outcome'
      fill_in 'complete_completed_at', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
      select @product.name, from: 'complete_product_trained_on_id'
      fill_in 'complete_duration_hours', with: '1'
      fill_in 'complete_constituent_summary', with: 'Practicamos los subtítulos y guardamos contactos.'
      select 'Spanish', from: 'complete_summary_locale'
      fill_in 'complete_internal_notes', with: 'PRIVATE GUARDIAN TRAINING OBSERVATIONS 1724'
      click_button 'Save completed report'
      assert_text 'Training session completed successfully.'
      assert requested.reload.status_completed?

      switch_user(admin, bypass_mfa_enrollment: true)
      visit admin_application_path(managed)
      within 'section[aria-labelledby="admin-training-heading"]' do
        assert_text '3 completed, 0 reserved, 0 remaining of 3'
        assert_text @trainer.full_name
        assert_link 'View Details', href: trainers_training_session_path(requested)
        assert_button 'Unassign Trainer'
      end
      take_screenshot('admin-between-appointments-at-quota', html: true, full: true)
      accept_confirm { click_button 'Unassign Trainer' }
      assert_text 'Trainer assignment removed.'
      assert_nil managed.reload.assigned_trainer_id
      assert_equal 3, managed.training_sessions.completed_sessions.count
      assert_equal 'PRIVATE GUARDIAN TRAINING OBSERVATIONS 1724', requested.reload.internal_notes
      assert_no_button 'Unassign Trainer'
      take_screenshot('admin-coverage-removed-completed-reports-retained', html: true, full: true)

      switch_user(manager)
      page.current_window.resize_to(375, 812)
      visit constituent_portal_training_sessions_path(locale: 'es')
      find("a[href='#{constituent_portal_training_session_path(requested)}']").click
      assert_selector 'div[lang=es]', text: 'Practicamos los subtítulos y guardamos contactos.'
      assert_text dependent.full_name
      assert_link 'Guía para practicar subtítulos'
      assert_no_text 'PRIVATE GUARDIAN TRAINING OBSERVATIONS 1724'
      assert_no_horizontal_overflow
      take_screenshot('guardian-new-summary-exact-demo-guides-narrow', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 900)
    end
  end
end
