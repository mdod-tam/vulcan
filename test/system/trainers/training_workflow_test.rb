# frozen_string_literal: true

require 'application_system_test_case'

module Trainers
  class TrainingWorkflowTest < ApplicationSystemTestCase
    setup do
      @trainer = create(:trainer)
      @constituent = create(:constituent, first_name: 'Morgan', last_name: 'Learner')
      @application = create(:application, :approved, :with_all_proofs, user: @constituent, assigned_trainer: @trainer, application_date: Date.current)
      @session = create(:training_session, application: @application, trainer: @trainer)
      @product = create(:product, name: 'Practice captions device')
      @other_product = create(:product, name: 'Alternative practice device')
      create(:product_resource, product: @product, title: 'Captions practice guide')
      create(:product_resource, product: @product, title: 'Guía para practicar subtítulos', locale: 'es')
      system_test_sign_in(@trainer)
    end

    teardown do
      Timeout.timeout(10) { Capybara.current_session.server&.wait_for_pending_requests }
    end

    test 'trainer schedules from blank agreement then restores and corrects an early completion report' do
      @session.destroy!
      @application.update!(assigned_trainer: nil)
      admin = create(:admin)
      switch_user(admin)
      visit admin_application_path(@application)
      within '[data-testid="trainer-assignment-section"]' do
        find('#trainer_id option', text: @trainer.full_name).select_option
        click_button 'Assign Trainer'
      end
      assert_equal @trainer.id, @application.reload.assigned_trainer_id
      @session = @application.latest_training_session
      assert @session.status_requested?
      take_screenshot('admin-assigns-current-trainer', html: true, full: true)
      switch_user(@trainer)
      visit trainers_dashboard_path
      within '#needs-scheduling-section' do
        assert_text @constituent.full_name
        assert_link 'View/Schedule', href: trainers_training_session_path(@session)
      end
      take_screenshot('trainer-dashboard-assignment-needs-scheduling', html: true, full: true)
      within('#needs-scheduling-section') { click_link 'View All' }
      assert_link 'View/Schedule', href: trainers_training_session_path(@session)
      take_screenshot('trainer-requested-session-list-entry', html: true, full: true)
      click_link 'View/Schedule'
      assert_selector 'h1', text: 'Training Session #1 Details'
      assert_field 'schedule_scheduled_for', with: ''
      assert_selector '#schedule_scheduled_for[required]'
      assert_selector '#schedule_internal_notes'
      assert_no_selector '#training-outcome'
      take_screenshot('trainer-requested-blank-agreement', html: true, full: true)

      past_time = 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
      fill_in 'schedule_scheduled_for', with: past_time
      fill_in 'schedule_location', with: ''
      fill_in 'schedule_internal_notes', with: 'Call before arrival; preparation notes stay private.'
      click_button 'Schedule appointment'

      assert_action_error('schedule')
      assert_field 'schedule_scheduled_for', with: past_time
      assert_field 'schedule_location', with: ''
      assert_field 'schedule_internal_notes', with: 'Call before arrival; preparation notes stay private.'
      assert_selector '#schedule_scheduled_for[aria-invalid=true]'
      assert_selector '#schedule-errors:focus'
      find('#schedule-errors a').click
      assert_selector '#schedule_scheduled_for:focus'
      take_screenshot('trainer-schedule-restored-error', html: true, full: true)

      planned_time = 3.days.from_now.strftime('%Y-%m-%dT%H:%M')
      fill_in 'schedule_scheduled_for', with: planned_time
      fill_in 'schedule_location', with: 'Library room 2'
      observe_native_submission
      find('input[type=submit][value="Schedule appointment"]').double_click
      assert_text 'Training session scheduled successfully.'
      assert_equal 'scheduled', @session.reload.status
      assert_equal 1, Event.where(auditable: @session, action: 'training_scheduled').count
      assert_native_submission('Saving appointment…')
      assert_no_selector '#complete_completed_at'
      assert_no_selector '#no_show_no_show_notes'
      select 'Complete training', from: 'training-outcome'
      assert_field 'complete_completed_at', with: ''
      assert_selector :select, 'complete_product_trained_on_id', selected: 'Select a product'
      assert_field 'complete_internal_notes', with: 'Call before arrival; preparation notes stay private.'
      assert_selector '#complete_duration_hours[aria-describedby="duration_hours_hint"]'
      assert_no_selector '#reschedule_scheduled_for'

      rejected_time = 1.day.from_now.strftime('%Y-%m-%dT%H:%M')
      fill_in 'complete_completed_at', with: rejected_time
      select @product.name, from: 'complete_product_trained_on_id'
      fill_in 'complete_duration_hours', with: '1.25'
      fill_in 'complete_constituent_summary', with: 'We practised caption settings and saving contacts.'
      select 'Spanish', from: 'complete_summary_locale'
      fill_in 'complete_internal_notes', with: 'PRIVATE TRAINER OBSERVATIONS 8125'
      click_button 'Save completed report'
      2.times do |attempt|
        assert_action_error('complete')
        assert_selector :select, 'training-outcome', selected: 'Complete training'
        assert_field 'complete_completed_at', with: rejected_time
        assert_selector :select, 'complete_product_trained_on_id', selected: @product.name
        assert_field 'complete_duration_hours', with: '1.25'
        assert_field 'complete_constituent_summary', with: 'We practised caption settings and saving contacts.'
        assert_selector :select, 'complete_summary_locale', selected: 'Spanish'
        assert_field 'complete_internal_notes', with: 'PRIVATE TRAINER OBSERVATIONS 8125'
        assert_selector 'input[type=submit][value="Save completed report"]:not([disabled])'
        click_button 'Save completed report' if attempt.zero?
      end
      select 'Reschedule at constituent request', from: 'training-outcome'
      assert_field 'reschedule_scheduled_for', with: ''
      assert_no_selector '#complete_completed_at:not([disabled])', visible: :all
      select 'Complete training', from: 'training-outcome'
      assert_field 'complete_completed_at', with: rejected_time
      assert_field 'complete_constituent_summary', with: 'We practised caption settings and saving contacts.'
      page.current_window.resize_to(375, 812)
      take_screenshot('trainer-completion-restored-narrow', html: true, full: true)
      assert_no_horizontal_overflow

      actual_time = 2.hours.ago.strftime('%Y-%m-%dT%H:%M')
      fill_in 'complete_completed_at', with: actual_time
      select @other_product.name, from: 'complete_product_trained_on_id'
      select @product.name, from: 'complete_product_trained_on_id'
      fill_in 'complete_duration_hours', with: '1.5'
      fill_in 'complete_constituent_summary', with: 'We practised captions and agreed to review the guide.'
      select 'English', from: 'complete_summary_locale'
      fill_in 'complete_internal_notes', with: ''
      observe_native_submission
      find('input[type=submit][value="Save completed report"]').double_click

      assert_text 'Training session completed successfully.'
      assert_text 'Actual completion'
      assert_text 'Report submitted'
      assert_text 'Captions practice guide'
      assert_no_selector '#training-outcome'
      assert_field 'schedule_additional_scheduled_for', with: ''
      assert_selector '#schedule_additional_scheduled_for[required]'
      assert_equal 'completed', @session.reload.status
      assert_equal Time.zone.parse(actual_time), @session.completed_at
      assert_equal Time.zone.parse(planned_time), @session.scheduled_for
      assert_equal '', @session.internal_notes
      assert_equal 'We practised captions and agreed to review the guide.', @session.constituent_summary
      assert_equal 1, Event.where(auditable: @session, action: 'training_completed').count
      assert_native_submission('Saving report…')
      take_screenshot('trainer-early-completion-with-next-agreement-blank', html: true, full: true)
      assert_no_horizontal_overflow
      @constituent.update!(locale: 'es')
      switch_user(@constituent)
      page.current_window.resize_to(375, 812)
      visit constituent_portal_dashboard_path(locale: 'es')
      find("a[href='#{constituent_portal_training_session_path(@session)}']").click
      assert_selector 'div[lang=en]', text: 'We practised captions and agreed to review the guide.'
      assert_text 'Escrito en inglés.'
      assert_link 'Guía para practicar subtítulos'
      assert_link 'Captions practice guide'
      assert_text 'No se proporciona traducción automática.'
      assert_no_text 'PRIVATE TRAINER OBSERVATIONS 8125'
      assert_no_horizontal_overflow
      take_screenshot('constituent-new-summary-authored-language-and-demo-guides', html: true, full: true)
      visit constituent_portal_products_path(locale: 'es')
      assert_no_text @product.name
    ensure
      page.current_window.resize_to(1200, 900)
    end

    test 'guardian coordinating contact and requested cancellation remain usable at a narrow viewport' do
      manager = create(:constituent, first_name: 'Sam', last_name: 'Guardian', locale: 'es',
                                     physical_address_1: 'Managing Guardian Avenue')
      @constituent.update!(email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local", dependent_email: manager.email)
      create(:guardian_relationship, guardian_user: manager, dependent_user: @constituent)
      @application.update!(managing_guardian: manager)
      page.current_window.resize_to(375, 812)
      visit trainers_training_session_path(@session)
      assert_text manager.email
      assert_text 'Managing Guardian Avenue'
      assert_no_link 'View Application', href: admin_application_path(@application)
      assert_field 'schedule_scheduled_for', with: ''
      select 'Constituent', from: 'cancel_cancellation_initiator'
      fill_in 'cancel_cancellation_reason', with: '   '
      click_button 'Cancel appointment'
      assert_action_error('cancel')
      assert_selector :select, 'cancel_cancellation_initiator', selected: 'Constituent'
      assert_field 'cancel_cancellation_reason', with: '   '
      fill_in 'cancel_cancellation_reason', with: 'The managing guardian declined this unscheduled appointment.'
      cancel_submit = find('input[type=submit][value="Cancel appointment"]')
      cancel_submit.scroll_to(:center)
      assert_not cancel_submit.disabled?
      cancel_style = page.evaluate_script <<~JS
        (() => {
          const style = getComputedStyle(document.querySelector('input[value="Cancel appointment"]'));
          return { color: style.color, background: style.backgroundColor, visibility: style.visibility, opacity: style.opacity };
        })()
      JS
      assert_equal 'visible', cancel_style['visibility']
      assert_equal '1', cancel_style['opacity']
      assert_not_equal cancel_style['color'], cancel_style['background']
      puts "Cancellation submit computed style: #{cancel_style.to_json}"
      take_screenshot('trainer-guardian-requested-cancel-narrow', html: true, full: true)
      cancel_submit.scroll_to(:center)
      take_screenshot('trainer-guardian-cancel-submit-viewport', html: true, full: false)
      click_button 'Cancel appointment'

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
      @trainer.update!(locale: 'es')
      @session.update!(status: :scheduled, scheduled_for: 1.day.from_now.change(sec: 0))
      visit trainers_training_session_path(@session, locale: 'es')
      select 'Completar capacitación', from: 'training-outcome'
      future_time = 1.hour.from_now.strftime('%Y-%m-%dT%H:%M')
      fill_in 'complete_completed_at', with: future_time
      select @product.name, from: 'complete_product_trained_on_id'
      fill_in 'complete_duration_hours', with: '3'
      fill_in 'complete_constituent_summary', with: 'Practicamos los subtítulos durante una visita prolongada.'
      select 'español', from: 'complete_summary_locale'
      fill_in 'complete_internal_notes', with: 'Observaciones privadas para el personal.'
      click_button 'Guardar informe completado'
      assert_selector 'dialog[open]', text: '¿Confirma 3 horas?'
      assert_selector '[data-training-duration-confirmation-target=yesButton]:focus'
      take_screenshot('trainer-spanish-long-duration-confirmation', html: true, full: true)
      within('dialog[open]') { click_button 'No' }
      assert_no_selector 'dialog[open]'
      assert_selector '#complete_duration_hours:focus'
      assert_field 'complete_duration_hours', with: '3'

      fill_in 'complete_duration_hours', with: '2.75'
      click_button 'Guardar informe completado'
      assert_selector 'dialog[open]', text: '¿Confirma 2.75 horas?'
      within('dialog[open]') { click_button 'Sí' }
      assert_action_error('complete', heading: 'Corrija los siguientes errores')
      assert_field 'complete_completed_at', with: future_time
      assert_field 'complete_duration_hours', with: '2.75'
      assert_field 'complete_constituent_summary', with: 'Practicamos los subtítulos durante una visita prolongada.'
      assert_field 'complete_internal_notes', with: 'Observaciones privadas para el personal.'
      take_screenshot('trainer-spanish-confirmed-report-restored-error', html: true, full: true)

      fill_in 'complete_completed_at', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
      click_button 'Guardar informe completado'
      assert_selector 'dialog[open]', text: '¿Confirma 2.75 horas?'
      within('dialog[open]') { click_button 'Sí' }
      assert_text 'La sesión de capacitación se marcó como completada correctamente.'
      assert @session.reload.status_completed?
      assert_equal BigDecimal('2.75'), @session.duration_hours
      assert_equal 'es', @session.summary_locale
      take_screenshot('trainer-spanish-confirmed-long-report-completed', html: true, full: true)
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
      switch_user(admin)
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
      switch_user(@trainer)
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

      switch_user(admin)
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

    private

    def switch_user(user)
      page.current_window.resize_to(1200, 900)
      system_test_sign_out
      install_stimulus_error_reporting
      system_test_sign_in(user)
    end

    def assert_action_error(action, heading: 'Please correct the following errors')
      assert_selector "##{action.dasherize}-errors[role=alert]"
      assert_selector '[role=alert]', count: 1
      assert_no_selector '[data-testid="flash-alert"]'
      assert_selector "##{action.dasherize}-errors h3", text: heading
    end

    def observe_native_submission
      page.execute_script <<~JS
        window.trainingSubmissions = [];
        document.addEventListener('turbo:submit-start', event => {
          const submitter = event.detail.formSubmission.submitter;
          window.trainingSubmissions.push({ disabled: submitter.disabled, label: submitter.value });
        }, { once: true });
      JS
    end

    def assert_native_submission(label)
      assert_equal [{ 'disabled' => true, 'label' => label }], page.evaluate_script('window.trainingSubmissions')
    end

    def assert_no_horizontal_overflow
      assert page.evaluate_script('document.documentElement.scrollWidth <= window.innerWidth'), 'The narrow page overflows horizontally.'
    end
  end
end
