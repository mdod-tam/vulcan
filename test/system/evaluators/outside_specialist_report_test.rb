# frozen_string_literal: true

require 'application_system_test_case'

module Evaluators
  class OutsideSpecialistReportTest < ApplicationSystemTestCase
    include EvaluatorSystemAssertions

    test 'assigned administrator records a requested outside consultation through validation retry' do
      admin = create(:admin)
      product = create(:product, name: 'Consultation Device')
      replacement = create(:product, name: 'Corrected Consultation Device')
      evaluation = create(:evaluation, evaluator: admin, status: :requested, evaluation_date: nil, location: nil)
      system_test_sign_in(admin)
      visit evaluators_evaluation_path(evaluation)
      assert_selector '#schedule-evaluation-form'
      assert_selector '#complete-evaluation-form'
      take_screenshot('outside-specialist-requested', html: true, full: true)

      invalid_time = 1.day.from_now.strftime('%Y-%m-%dT%H:%M')
      within '#complete-evaluation-form' do
        select 'Outside-specialist consultation', from: 'Assessment source'
        fill_in 'Assessment/Consultation Date/Time', with: invalid_time
        fill_in 'Working Notes', with: 'Recommendations supplied in the outside specialist written consultation.'
        replace_product_selection('products_tried_inputs')
        replace_product_selection('recommended_product_ids', product)
        assert_selector '#complete_evaluation_location:not([required])[aria-required="false"]'
        click_button 'Mark as Completed'
      end

      assert_single_action_error('submit-report-errors')
      within '#complete-evaluation-form' do
        assert_selector :select, 'Assessment source', selected: 'Outside-specialist consultation'
        assert_field 'Assessment/Consultation Date/Time', with: invalid_time
        assert_field 'Working Notes', with: 'Recommendations supplied in the outside specialist written consultation.'
        assert_selector "input[name='evaluation[recommended_product_ids][]'][value='#{product.id}']:checked"
        assert_no_selector "input[name^='evaluation[products_tried_inputs]'][type='checkbox']:checked"
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')
      assert_equal 'requested', evaluation.reload.status
      page.current_window.resize_to(390, 844)
      take_screenshot('outside-specialist-restored-mobile', html: true, full: true)
      page.current_window.resize_to(1200, 800)

      actual_time = 2.days.ago.strftime('%Y-%m-%dT%H:%M')
      within '#complete-evaluation-form' do
        replace_product_selection('recommended_product_ids')
        assert_selector '#complete_evaluation_recommendation_notes[required][aria-required="true"]'
        fill_in 'Non-catalog products and recommendation details', with: 'Restored consultation context for an external model.'
        assert_field 'Non-catalog products and recommendation details', with: 'Restored consultation context for an external model.'
        replace_product_selection('recommended_product_ids', product)
        assert_selector '#complete_evaluation_recommendation_notes:not([required])[aria-required="false"]'
        fill_in 'Non-catalog products and recommendation details', with: ''
        replace_product_selection('products_tried_inputs', product, reaction: 'Neutral')
        assert_selector "#trial-#{product.id}:checked"
        assert_selector :select, "trial-#{product.id}-reaction", selected: 'Neutral'
        replace_product_selection('products_tried_inputs')
        fill_in 'Other Attendees', with: 'Specialist consultation interpreter'
        fill_in 'Other Attendees', with: ''
        fill_in 'Assessment/Consultation Date/Time', with: actual_time
        fill_in 'Working Notes', with: 'Corrected written specialist recommendation and consultation context.'
        replace_product_selection('recommended_product_ids', replacement)
      end
      take_screenshot('outside-specialist-corrected-inputs', html: true, full: true)
      within '#complete-evaluation-form' do
        click_button 'Mark as Completed'
      end

      assert_text 'Evaluation submitted successfully.'
      assert_text 'Outside-specialist consultation'
      assert_no_selector '#complete-evaluation-form'
      assert_equal 'completed', evaluation.reload.status
      assert_nil evaluation.evaluation_date
      assert_equal Time.zone.parse(actual_time), evaluation.appointment_completed_at
      assert evaluation.report_submitted_at.present?
      assert_empty evaluation.products_tried
      assert_empty evaluation.attendees
      assert_equal '', evaluation.recommendation_notes
      assert_equal [replacement.id], evaluation.recommended_product_ids
      assert_equal 'Corrected written specialist recommendation and consultation context.', evaluation.notes
      assert_equal [replacement.id], evaluation.application.equipment_needs.pluck(:product_id)
      take_screenshot('outside-specialist-completed', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'scheduled administrator can switch restored assessment source without weakening direct report requirements' do
      admin = create(:admin)
      product = create(:product, name: 'Source Switch Device')
      evaluation = create(:evaluation, evaluator: admin, status: :scheduled)
      system_test_sign_in(admin)
      visit evaluators_evaluation_path(evaluation)

      within '#complete-evaluation-form' do
        select 'Outside-specialist consultation', from: 'Assessment source'
        fill_in 'Assessment/Consultation Date/Time', with: 1.day.from_now.strftime('%Y-%m-%dT%H:%M')
        fill_in 'Location', with: ''
        fill_in 'Working Notes', with: 'Outside specialist written consultation context.'
        replace_product_selection('recommended_product_ids', product)
        replace_product_selection('products_tried_inputs')
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')

      within '#complete-evaluation-form' do
        select 'Direct assessment', from: 'Assessment source'
        assert_selector '#complete_evaluation_location[required][aria-required="true"]'
        fill_in 'Location', with: 'Assessment office'
        fill_in 'Assessment/Consultation Date/Time', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')
      assert_selector '#submit-report-errors', text: "Products tried can't be blank"
      assert_selector :select, 'Assessment source', selected: 'Direct assessment'
      take_screenshot('assessment-source-direct-restored', html: true, full: true)

      within '#complete-evaluation-form' do
        replace_product_selection('products_tried_inputs', product, reaction: 'Dissatisfied')
        assert_selector "#trial-#{product.id}:checked"
        assert_selector :select, "trial-#{product.id}-reaction", selected: 'Dissatisfied'
      end
      take_screenshot('assessment-source-direct-trial-selected-full', html: true, full: true)

      within '#complete-evaluation-form' do
        replace_product_selection('products_tried_inputs')
        assert_no_selector "input[name^='evaluation[products_tried_inputs]'][type='checkbox']:checked"
        select 'Outside-specialist consultation', from: 'Assessment source'
        fill_in 'Location', with: ''
        assert_selector '#complete_evaluation_location:not([required])[aria-required="false"]'
        assert_field 'Working Notes', with: 'Outside specialist written consultation context.'
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'outside_specialist', evaluation.reload.assessment_source
      assert_empty evaluation.products_tried
      assert_equal '', evaluation.location
      take_screenshot('assessment-source-outside-completed', html: true, full: true)
    end
  end
end
