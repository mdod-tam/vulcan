# frozen_string_literal: true

require 'application_system_test_case'

module Evaluators
  class EvaluationLifecycleTest < ApplicationSystemTestCase
    include EvaluatorSystemAssertions
    include EvaluationSystemTestSetup

    test 'requested evaluation schedules reschedules and completes through recoverable report errors' do
      @evaluation.update!(status: :requested, evaluation_date: nil)
      past_time = 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
      visit evaluators_evaluation_path(@evaluation)
      assert_selector 'label[for="schedule_evaluation_evaluation_date"] .text-danger-600', text: '*'
      assert_selector 'label[for="schedule_evaluation_evaluation_date"] .sr-only', text: '(required)', visible: :all
      assert_selector '#schedule_evaluation_evaluation_date[required]'

      within '#schedule-evaluation-form' do
        fill_in 'Evaluation Date/Time', with: past_time
        fill_in 'Location', with: ''
        fill_in 'Working Notes', with: 'Call the contact person before arrival'
        click_button 'Schedule Evaluation'
      end

      assert_text 'Failed to schedule evaluation:'
      assert_single_action_error('schedule-errors')
      within '#schedule-evaluation-form' do
        assert_field 'Evaluation Date/Time', with: past_time
        assert_field 'Location', with: ''
        assert_field 'Working Notes', with: 'Call the contact person before arrival'
      end
      take_screenshot('evaluator-schedule-restored', html: true, full: true)

      future_time = 3.days.from_now.strftime('%Y-%m-%dT%H:%M')
      within '#schedule-evaluation-form' do
        fill_in 'Evaluation Date/Time', with: future_time
        fill_in 'Location', with: 'Library'
        fill_in 'Working Notes', with: 'Confirmed directly with the contact person'
        click_button 'Schedule Evaluation'
      end

      assert_text 'Evaluation scheduled successfully.'
      assert_equal 'scheduled', @evaluation.reload.status
      within '#reschedule-evaluation-form' do
        fill_in 'New Date/Time', with: past_time
        fill_in 'Location', with: ''
        fill_in 'Reason for Rescheduling', with: 'A different time is needed'
        click_button 'Reschedule Evaluation'
      end

      assert_text 'Failed to reschedule evaluation:'
      assert_single_action_error('reschedule-errors')
      within '#reschedule-evaluation-form' do
        assert_field 'New Date/Time', with: past_time
        assert_field 'Location', with: ''
        assert_field 'Reason for Rescheduling', with: 'A different time is needed'
      end

      within '#reschedule-evaluation-form' do
        fill_in 'New Date/Time', with: 4.days.from_now.strftime('%Y-%m-%dT%H:%M')
        fill_in 'Location', with: 'Another Library'
        fill_in 'Reason for Rescheduling', with: 'Contact person confirmed the new time'
        click_button 'Reschedule Evaluation'
      end

      assert_text 'Evaluation rescheduled successfully.'
      assert_equal 'Another Library', @evaluation.reload.location
      assert_equal 'Contact person confirmed the new time', @evaluation.reschedule_reason

      original_date = @evaluation.evaluation_date
      appointment_time = 1.day.from_now.strftime('%Y-%m-%dT%H:%M')
      visit evaluators_evaluation_path(@evaluation)

      within '#complete-evaluation-form' do
        fill_in 'Appointment Date/Time', with: appointment_time
        fill_in 'Location', with: 'Retry Library'
        fill_in 'Other Attendees', with: 'Interpreter, Family friend'
        fill_in 'Working Notes', with: 'Detailed report observations'
        replace_product_selection('products_tried_inputs', @product)
        replace_product_selection('recommended_product_ids')
        fill_in 'Non-catalog products and recommendation details', with: 'Non-catalog recommendation retained during retry.'
        click_button 'Mark as Completed'
      end

      2.times do |attempt|
        assert_text 'Failed to submit evaluation:'
        assert_single_action_error('submit-report-errors')
        within '#complete-evaluation-form' do
          assert_field 'Appointment Date/Time', with: appointment_time
          assert_field 'Location', with: 'Retry Library'
          assert_field 'Other Attendees', with: 'Interpreter, Family friend'
          assert_field 'Working Notes', with: 'Detailed report observations'
          assert_selector "input#trial-#{@product.id}:checked"
          assert_no_selector "input[name='evaluation[recommended_product_ids][]']:checked"
          click_button 'Mark as Completed' if attempt.zero?
        end
      end
      take_screenshot('evaluator-report-restored', html: true, full: true)
      assert_equal 'scheduled', @evaluation.reload.status

      corrected_time = 2.hours.ago.strftime('%Y-%m-%dT%H:%M')
      within '#complete-evaluation-form' do
        fill_in 'Appointment Date/Time', with: corrected_time
        fill_in 'Location', with: 'Corrected Library'
        fill_in 'Other Attendees', with: ''
        fill_in 'Working Notes', with: 'Corrected report observations'
        replace_product_selection('products_tried_inputs', @replacement_product)
        replace_product_selection('recommended_product_ids', @replacement_product)
      end
      within '#complete-evaluation-form' do
        click_button 'Mark as Completed'
      end

      assert_text 'Evaluation submitted successfully.'
      assert_text 'Appointment Completed At'
      assert_text 'Report Submitted At'
      assert_text 'Working Notes'
      assert_no_selector '#complete-evaluation-form'
      assert_equal 'completed', @evaluation.reload.status
      assert_equal original_date, @evaluation.evaluation_date
      assert_equal 'Corrected report observations', @evaluation.notes
      assert_equal [], @evaluation.attendees
      assert_equal [@replacement_product.id], @evaluation.recommended_product_ids
      assert_equal({ @replacement_product.id.to_s => { 'selected' => '1', 'reaction' => 'Satisfied' } }, @evaluation.products_tried_inputs)
      assert_equal Time.zone.parse(corrected_time), @evaluation.appointment_completed_at
      take_screenshot('evaluator-report-completed', html: true, full: true)
    end
  end
end
