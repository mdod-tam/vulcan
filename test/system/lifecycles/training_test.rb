# frozen_string_literal: true

require 'application_system_test_case'

module Trainers
  class TrainingLifecycleTest < ApplicationSystemTestCase
    include TrainingSystemTestSetup

    test 'trainer schedules from blank agreement then restores and corrects an early completion report' do
      @session.destroy!
      @application.update!(assigned_trainer: nil)
      admin = create(:admin)
      switch_user(admin, bypass_mfa_enrollment: true)
      travel_to(3.hours.ago.change(sec: 0)) do
        visit admin_application_path(@application)
        within '[data-testid="trainer-assignment-section"]' do
          find('#trainer_id option', text: @trainer.full_name).select_option
          click_button 'Assign Trainer'
        end
        assert_equal @trainer.id, @application.reload.assigned_trainer_id
        @session = @application.latest_training_session
        assert @session.status_requested?
      end
      switch_user(@trainer, bypass_mfa_enrollment: true)
      visit trainers_dashboard_path
      within '#needs-scheduling-section' do
        assert_text @constituent.full_name
        assert_link 'View/Schedule', href: trainers_training_session_path(@session)
      end
      within('#needs-scheduling-section') { click_link 'View all assigned sessions' }
      assert_link 'View/Schedule', href: trainers_training_session_path(@session)
      click_link 'View/Schedule'
      assert_selector 'h1', text: 'Training Session #1 Details'
      assert_field 'schedule_scheduled_for', with: ''
      assert_selector '#schedule_scheduled_for[required]'
      assert_selector '#schedule_internal_notes'
      assert_no_selector '#training-outcome'

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
      assert_selector '[data-testid="flash-notice"][role="status"][aria-live="polite"]',
                      text: 'Training session scheduled successfully.'
      assert_equal 'scheduled', @session.reload.status
      assert_equal 1, Event.where(auditable: @session, action: 'training_scheduled').count
      assert_native_submission('Saving appointment…')
      assert_no_selector '#complete_completed_at'
      assert_no_selector '#no_show_no_show_notes'
      assert_selector 'h2#session-actions-heading', text: 'What happened?'
      assert_selector '[data-training-outcome-target="status"]:empty', visible: :all
      find_by_id('training-outcome').click
      select 'Complete training', from: 'training-outcome'
      assert_selector '#training-outcome:focus'
      assert_selector '[data-training-outcome-target="status"][role="status"][aria-live="polite"]',
                      text: 'Complete training form shown below. Fill in the details, then save.'
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
        assert_selector '[data-training-outcome-target="status"]:empty', visible: :all
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
      assert_selector '[data-training-outcome-target="status"]',
                      text: 'Reschedule at constituent request form shown below. Fill in the details, then save.'
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
      assert_selector '[data-testid="flash-notice"][role="status"]', text: 'Training session completed successfully.'
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
  end
end
