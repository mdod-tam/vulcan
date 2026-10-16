# frozen_string_literal: true

require 'application_system_test_case'

module Evaluators
  class EvaluationOutcomesTest < ApplicationSystemTestCase
    include EvaluatorSystemAssertions

    setup do
      @evaluator = create(:evaluator)
      @product = create(:product, name: 'Outcome Trial Device')
      @evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled, evaluation_date: 2.days.from_now)
      @evaluation.update!(products_tried: [], recommended_product_ids: [])
      system_test_sign_in(@evaluator)
    end

    test 'an empty recommendation is rejected and can become an explicit no suitable product decision' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report
      assert_no_selector '#complete-evaluation-form input[type=radio]'
      assert_selector '#catalog-recommendations-group'
      within '#complete-evaluation-form' do
        click_button 'Mark as Completed'
      end
      assert_no_selector '#submit-report-errors'
      assert_equal 'scheduled', @evaluation.reload.status
      page.execute_script('document.getElementById("complete-evaluation-form").noValidate = true')
      within '#complete-evaluation-form' do
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')
      within '#complete-evaluation-form' do
        assert_field 'Working Notes', with: 'Appointment observations recorded.'
        assert_field 'Location', with: 'Accessible library meeting room'
      end
      assert_equal 'scheduled', @evaluation.reload.status
      take_screenshot('recommendations-empty-restored', html: true, full: true)

      within '#complete-evaluation-form' do
        check 'No suitable product was found'
        fill_in 'Non-catalog products and recommendation details', with: 'Arrange a specialist assessment; no suitable product was found.'
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'no_suitable_product', @evaluation.reload.recommendation_outcome
      assert_equal 1, Event.where(action: 'evaluation_completed', auditable: @evaluation).count
      assert_no_selector '#reschedule-evaluation-form'
      take_screenshot('recommendations-no-suitable-completed', html: true, full: true)
    end

    test 'a checked trial requires a satisfaction choice and mixed recommendations survive rejection and correction' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report(appointment_time: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'))
      within '#complete-evaluation-form' do
        find("#trial-#{@product.id}").check
        assert_selector "#trial-#{@product.id}-reaction[required]"
        assert_equal false, page.evaluate_script('document.getElementById("complete-evaluation-form").checkValidity()')
        select 'Dissatisfied', from: "trial-#{@product.id}-reaction"
        replace_product_selection('recommended_product_ids', @product)
        fill_in 'Non-catalog products and recommendation details', with: 'Also recommend a non-catalog visual alert device.'
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')
      2.times do |attempt|
        within '#complete-evaluation-form' do
          assert_selector "#trial-#{@product.id}:checked"
          assert_selector :select, 'Satisfaction with Outcome Trial Device', selected: 'Dissatisfied'
          assert_field 'Non-catalog products and recommendation details', with: 'Also recommend a non-catalog visual alert device.'
          click_button 'Mark as Completed' if attempt.zero?
        end
      end
      take_screenshot('recommendations-mixed-restored', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('recommendations-mixed-restored-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 800)
      within '#complete-evaluation-form' do
        select 'Neutral', from: "trial-#{@product.id}-reaction"
        fill_in 'Appointment Date/Time', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'Neutral', @evaluation.reload.products_tried.sole['reaction']
      assert_equal [@product.id], @evaluation.recommended_product_ids
      assert_equal 'catalog_products', @evaluation.recommendation_outcome
      assert_equal 'Also recommend a non-catalog visual alert device.', @evaluation.recommendation_notes
      assert_equal [@product.id], @evaluation.application.equipment_needs.pluck(:product_id)
      assert_text 'Outcome Trial Device — Neutral'
      take_screenshot('recommendations-mixed-completed', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'no suitable product conflicts preserve selections and can be corrected without losing draft details' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report
      within '#complete-evaluation-form' do
        replace_product_selection('products_tried_inputs', @product)
        replace_product_selection('recommended_product_ids', @product)
        fill_in 'Non-catalog products and recommendation details', with: 'Client-facing next steps.'
        check 'No suitable product was found'
      end
      assert_equal false, page.evaluate_script('document.getElementById("complete-evaluation-form").checkValidity()')
      page.execute_script('document.getElementById("complete-evaluation-form").noValidate = true')
      within '#complete-evaluation-form' do
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')
      assert_checked_field 'No suitable product was found'
      assert_selector "input[name='evaluation[recommended_product_ids][]'][value='#{@product.id}']:checked"
      take_screenshot('recommendations-conflict-restored', html: true, full: true)
      within '#complete-evaluation-form' do
        uncheck 'No suitable product was found'
        find("#trial-#{@product.id}").uncheck
        assert_no_selector "#trial-#{@product.id}-reaction", visible: true
        find("#trial-#{@product.id}").check
        assert_selector :select, 'Satisfaction with Outcome Trial Device', selected: 'Satisfied'
        select 'Dissatisfied', from: "trial-#{@product.id}-reaction"
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'Dissatisfied', @evaluation.reload.products_tried.sole['reaction']
      assert_equal 'Client-facing next steps.', @evaluation.recommendation_notes
      take_screenshot('recommendations-conflict-corrected', html: true, full: true)
    end

    test 'recommendations and trial satisfaction remain usable without JavaScript through rejection' do
      browser = page.driver.browser
      browser.disable_javascript
      visit evaluators_evaluation_path(@evaluation)
      fill_report(appointment_time: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'))
      within '#complete-evaluation-form' do
        find("#trial-#{@product.id}").check
        select 'Neutral', from: "trial-#{@product.id}-reaction"
        replace_product_selection('recommended_product_ids', @product)
        fill_in 'Non-catalog products and recommendation details', with: 'An additional non-catalog recommendation.'
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')
      assert_selector "#trial-#{@product.id}:checked"
      assert_selector :select, 'Satisfaction with Outcome Trial Device', selected: 'Neutral'
      take_screenshot('recommendations-restored-without-js', html: true, full: true)
      within '#complete-evaluation-form' do
        fill_in 'Appointment Date/Time', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'Neutral', @evaluation.reload.products_tried.sole['reaction']
      assert_equal 'catalog_products', @evaluation.recommendation_outcome
    ensure
      browser&.page&.command('Emulation.setScriptExecutionDisabled', value: false)
    end

    test 'an outside catalog report records recommendations and optional catalog trials' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report
      within '#complete-evaluation-form' do
        fill_in 'Non-catalog products and recommendation details', with: 'Recommend a specialist hearing clinic assessment.'
        replace_product_selection('products_tried_inputs', @product, reaction: 'Dissatisfied')
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'outside_catalog', @evaluation.reload.recommendation_outcome
      assert_equal [@product.id], @evaluation.products_tried_field
      assert_empty @evaluation.recommended_product_ids
      assert_text 'Outcome Trial Device — Dissatisfied'
      take_screenshot('recommendations-external-completed', html: true, full: true)
    end

    test 'a restored external report can add and remove catalog recommendations and clear details' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report(appointment_time: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'))
      within '#complete-evaluation-form' do
        fill_in 'Non-catalog products and recommendation details', with: 'Restored recommendation context.'
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')
      within '#complete-evaluation-form' do
        replace_product_selection('recommended_product_ids', @product)
        assert_selector '#complete_evaluation_recommendation_notes:not([required])[aria-required="false"]'
        replace_product_selection('recommended_product_ids')
        assert_selector '#complete_evaluation_recommendation_notes[required][aria-required="true"]'
        replace_product_selection('recommended_product_ids', @product)
        replace_product_selection('products_tried_inputs', @product, reaction: 'Satisfied')
        fill_in 'Non-catalog products and recommendation details', with: ''
        fill_in 'Appointment Date/Time', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'catalog_products', @evaluation.reload.recommendation_outcome
      assert_equal '', @evaluation.recommendation_notes
      assert_equal [@product.id], @evaluation.recommended_product_ids
      take_screenshot('recommendations-catalog-completed', html: true, full: true)
    end

    test 'working notes remain separate and editable through rejection replacement refresh and clearing' do
      requested = create(:evaluation, evaluator: @evaluator, status: :requested, evaluation_date: nil)
      original_notes = requested.notes
      visit evaluators_evaluation_path(requested)
      failed_event = Event.new
      failed_event.errors.add(:base, 'Audit record unavailable')
      AuditEventService.stub(:log, ->(**) { raise ActiveRecord::RecordInvalid, failed_event }) do
        within '#working-notes-form' do
          fill_in 'Working Notes', with: 'Reached voicemail; try again tomorrow.'
          click_button 'Save working notes'
        end
        assert_selector '#save-working-notes-errors'
        assert_single_action_error('save-working-notes-errors')
      end
      assert_field 'working_evaluation_working_notes', with: 'Reached voicemail; try again tomorrow.'
      assert_nil requested.reload.working_notes
      take_screenshot('working-notes-restored', html: true, full: true)

      within '#working-notes-form' do
        fill_in 'Working Notes', with: 'Contact person confirmed the appointment arrangements.'
        click_button 'Save working notes'
      end
      assert_text 'Working notes saved.'
      page.refresh
      assert_field 'working_evaluation_working_notes', with: 'Contact person confirmed the appointment arrangements.'
      assert_equal 'requested', requested.reload.status
      assert_nil requested.evaluation_date
      assert_equal original_notes, requested.notes
      take_screenshot('working-notes-saved', html: true, full: true)

      within '#working-notes-form' do
        fill_in 'Working Notes', with: ''
        click_button 'Save working notes'
      end
      assert_text 'Working notes saved.'
      assert_nil requested.reload.working_notes
      assert_equal 'requested', requested.status
      take_screenshot('working-notes-cleared', html: true, full: true)

      completed = create(:evaluation, :completed, evaluator: @evaluator, working_notes: 'Preparation notes retained.')
      visit evaluators_evaluation_path(completed)
      assert_no_selector '#working-notes-form'
      assert_selector 'section[aria-labelledby="working-notes-heading"]', text: 'Preparation notes retained.'
      assert_selector '#supplemental-notes-form'
      take_screenshot('working-notes-completed-readonly', html: true, full: true)

      original_report = completed.notes
      note_errors = ActiveModel::Errors.new(completed)
      note_errors.add(:post_completion_notes, 'could not be saved. Try again.')
      begin
        Evaluation.any_instance.stubs(:update).returns(false)
        Evaluation.any_instance.stubs(:errors).returns(note_errors)
        within '#supplemental-notes-form' do
          fill_in 'Working Notes', with: 'Attempted supplemental follow-up.'
          click_button 'Add Note'
        end
        assert_selector '#supplemental-notes-errors'
        assert_single_action_error('supplemental-notes-errors')
        assert_field 'Working Notes', with: 'Attempted supplemental follow-up.'
        assert_equal 'supplemental-notes-errors', page.evaluate_script('document.activeElement.id')
        assert_selector '#supplemental_evaluation_post_completion_notes[aria-invalid=true]'
        assert_selector '#supplemental_evaluation_post_completion_notes[aria-describedby~="supplemental-notes-post-completion-notes-error"]'
        page.driver.browser.keyboard.type(:tab)
        page.driver.browser.keyboard.type(:enter)
        assert_equal 'supplemental_evaluation_post_completion_notes', page.evaluate_script('document.activeElement.id')
        take_screenshot('supplemental-notes-restored', html: true, full: true)
      ensure
        Evaluation.any_instance.unstub(:update)
        Evaluation.any_instance.unstub(:errors)
      end

      within '#supplemental-notes-form' do
        fill_in 'Working Notes', with: 'Confirmed supplemental next steps.'
        click_button 'Add Note'
      end
      assert_text 'Evaluation updated successfully.'
      page.refresh
      assert_field 'Working Notes', with: 'Confirmed supplemental next steps.'
      assert_equal 'Confirmed supplemental next steps.', completed.reload.post_completion_notes
      take_screenshot('supplemental-notes-saved', html: true, full: true)

      within '#supplemental-notes-form' do
        fill_in 'Working Notes', with: ''
        click_button 'Update Note'
      end
      assert_text 'Evaluation updated successfully.'
      assert_equal '', completed.reload.post_completion_notes
      assert_equal original_report, completed.notes
      assert_equal 'Preparation notes retained.', completed.working_notes
      assert_equal 'completed', completed.status
      take_screenshot('supplemental-notes-cleared', html: true, full: true)
    end

    test 'keyboard report errors focus their summary and recommendation group with sufficient button contrast' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report
      within '#complete-evaluation-form' do
        replace_product_selection('products_tried_inputs', @product)
        replace_product_selection('recommended_product_ids')
      end
      styles = page.evaluate_script(<<~JS)
        (() => {
          const style = getComputedStyle(document.querySelector('#complete-evaluation-form input[type=submit]'));
          return {foreground: style.color, background: style.backgroundColor};
        })()
      JS
      assert_operator color_contrast(styles.fetch('foreground'), styles.fetch('background')), :>=, 4.5
      page.execute_script('document.getElementById("complete-evaluation-form").noValidate = true')
      find_by_id('complete_evaluation_notes').send_keys(:tab)
      assert_equal 'Mark as Completed', page.evaluate_script('document.activeElement.value')
      page.driver.browser.keyboard.type(:enter)
      assert_selector '#submit-report-errors'
      assert_single_action_error('submit-report-errors')
      take_screenshot('report-error-summary-focused', html: true, full: true)
      assert_equal 'submit-report-errors', page.evaluate_script('document.activeElement.id')
      assert_selector '#catalog-recommendations-group[aria-invalid=true]'
      assert_selector '#catalog-recommendations-group[aria-describedby="submit-report-recommended-product-ids-error"]'
      page.driver.browser.keyboard.type(:tab)
      assert_equal '#catalog-recommendations-group', page.evaluate_script('document.activeElement.getAttribute("href")')
      page.driver.browser.keyboard.type(:enter)
      assert_equal 'catalog-recommendations-group', page.evaluate_script('document.activeElement.id')
    end

    test 'the narrow list provides keyboard scrolling and exposes a pointer action without page overflow' do
      page.current_window.resize_to(320, 812)
      visit evaluators_evaluations_path(status: 'scheduled')
      assert_selector 'main [role=region][tabindex="0"]'
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const viewport = window.innerWidth;
          return {
            viewport, clientWidth: document.documentElement.clientWidth, scrollWidth: document.documentElement.scrollWidth,
            overflowing: Array.from(document.querySelectorAll('body *')).filter(element => {
              const rect = element.getBoundingClientRect();
              return rect.width > 0 && rect.right > viewport &&
                (!element.closest('[role=region]') || getComputedStyle(element).position === 'absolute');
            }).slice(0, 12).map(element => ({
              tag: element.tagName, id: element.id, classes: element.className,
              right: element.getBoundingClientRect().right, clientWidth: element.clientWidth, scrollWidth: element.scrollWidth,
              position: getComputedStyle(element).position
            }))
          };
        })()
      JS
      take_screenshot('evaluation-list-narrow-overflow-diagnostic', html: true, full: true) if geometry.fetch('scrollWidth') > 320
      assert_operator geometry.fetch('scrollWidth'), :<=, 320, geometry.inspect
      24.times do
        page.driver.browser.keyboard.type(:tab)
        break if page.evaluate_script('document.activeElement.getAttribute("role")') == 'region'
      end
      assert_equal 'region', page.evaluate_script('document.activeElement.getAttribute("role")')
      assert_equal 'auto', page.evaluate_script('getComputedStyle(document.activeElement).overflowX')
      24.times do
        page.driver.browser.keyboard.type(:right)
        break if action_visible_in_scroll_region?
      end
      take_screenshot('evaluation-list-narrow-scroll-action', html: true, full: true)
      assert action_visible_in_scroll_region?
      assert_current_path evaluators_evaluations_path(status: 'scheduled')
      find("tbody a[href='#{evaluators_evaluation_path(@evaluation)}']").click
      assert_current_path evaluators_evaluation_path(@evaluation)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    private

    def fill_report(appointment_time: 1.hour.ago.strftime('%Y-%m-%dT%H:%M'))
      within '#complete-evaluation-form' do
        fill_in 'Appointment Date/Time', with: appointment_time
        fill_in 'Location', with: 'Accessible library meeting room'
        fill_in 'Working Notes', with: 'Appointment observations recorded.'
      end
    end

    def action_visible_in_scroll_region?
      page.evaluate_script(<<~JS)
        (() => {
          const region = document.querySelector('main [role=region]'), link = region.querySelector('tbody a');
          const container = region.getBoundingClientRect(), action = link.getBoundingClientRect();
          return action.left >= container.left && action.right <= container.right;
        })()
      JS
    end

    def color_contrast(foreground, background)
      luminances = [foreground, background].map do |color|
        channels = color.scan(/[\d.]+/).first(3).map do |channel|
          value = channel.to_f / 255
          value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055)**2.4
        end
        channels.zip([0.2126, 0.7152, 0.0722]).sum { |channel, weight| channel * weight }
      end
      brighter, darker = luminances.sort.reverse
      (brighter + 0.05) / (darker + 0.05)
    end
  end
end
