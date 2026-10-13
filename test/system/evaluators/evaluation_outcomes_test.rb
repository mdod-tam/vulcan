# frozen_string_literal: true

require 'application_system_test_case'

module Evaluators
  class EvaluationOutcomesTest < ApplicationSystemTestCase
    include EvaluatorSystemAssertions

    setup do
      @evaluator = create(:evaluator)
      @product = create(:product, name: 'Outcome Trial Device')
      @evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled, evaluation_date: 2.days.from_now)
      system_test_sign_in(@evaluator)
    end

    test 'report outcome is an explicit choice through browser and server rejection' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report
      assert_no_selector '#complete-evaluation-form input[type=radio]:checked'
      assert_equal false, page.evaluate_script('document.getElementById("complete-evaluation-form").checkValidity()')
      assert_no_selector '#catalog-recommendations-group', visible: true
      within '#complete-evaluation-form' do
        click_button 'Mark as Completed'
      end
      assert_no_selector '#submit-report-errors'
      assert_equal 'scheduled', @evaluation.reload.status
      take_screenshot('outcome-choice-required', html: true, full: true)

      page.execute_script('document.getElementById("complete-evaluation-form").noValidate = true')
      within '#complete-evaluation-form' do
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')
      assert_selector '#submit-report-errors a[href="#recommendation-outcome-group"]', text: 'Recommendation outcome must be selected'
      assert_no_selector '#complete-evaluation-form input[type=radio]:checked'
      assert_field 'Evaluation Report Notes', with: 'Appointment observations recorded.'
      assert_field 'Location', with: 'Accessible library meeting room'
      assert_equal 'scheduled', @evaluation.reload.status
      take_screenshot('outcome-choice-restored', html: true, full: true)

      within '#complete-evaluation-form' do
        choose 'No suitable product'
        fill_in 'Recommendation details', with: 'Arrange a specialist assessment; no suitable catalog product.'
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'no_suitable_product', @evaluation.reload.recommendation_outcome
      assert_equal 1, Event.where(action: 'evaluation_completed', auditable: @evaluation).count
      take_screenshot('outcome-choice-completed', html: true, full: true)
    end

    test 'Turbo blocks repeat clicks while a committed report response is pending and validation remains retryable' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report(appointment_time: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'))
      within '#complete-evaluation-form' do
        choose 'Catalog products'
        replace_product_selection('products_tried_field', @product)
        replace_product_selection('recommended_product_ids', @product)
        click_button 'Mark as Completed'
      end
      assert_single_action_error('submit-report-errors')
      assert_selector '#complete-evaluation-form input[type=submit]:not([disabled])', count: 1
      assert_checked_field 'Catalog products'
      fill_in 'Appointment Date/Time', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')

      response_waiting = Queue.new
      release_response = Queue.new
      original_delivery = EmailDelivery.method(:deliver_later)
      delayed_delivery = lambda do |delivery, **options|
        response_waiting << true
        release_response.pop
        original_delivery.call(delivery, **options)
      end
      EmailDelivery.stub(:deliver_later, delayed_delivery) do
        page.execute_script(<<~JS)
          window.evaluationSubmitCount = 0;
          document.getElementById('complete-evaluation-form').addEventListener('submit', () => {
            window.evaluationSubmitCount += 1;
          });
          document.querySelector('#complete-evaluation-form input[type=submit]').click();
        JS
        begin
          wait_until(time: 10) { !response_waiting.empty? }
          assert_selector '#complete-evaluation-form[aria-busy=true] input[type=submit][disabled][value="Submitting report..."]'
          assert_equal 'completed', @evaluation.reload.status
          assert_equal 1, Event.where(action: 'evaluation_completed', auditable: @evaluation).count
          page.execute_script("document.querySelector('#complete-evaluation-form input[type=submit]').click()")
          assert_equal 1, page.evaluate_script('window.evaluationSubmitCount')
          take_screenshot('report-submission-pending', html: true, full: true)
        ensure
          release_response << true
        end
        assert_text 'Evaluation submitted successfully.'
        assert_no_selector '#complete-evaluation-form'
        assert_equal 1, Event.where(action: 'evaluation_completed', auditable: @evaluation).count
        take_screenshot('report-submission-completed', html: true, full: true)
      end
    end

    test 'an external outcome survives rejection and can become no suitable product with no catalog products' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report(appointment_time: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'))
      within '#complete-evaluation-form' do
        choose 'Outside the catalog'
        fill_in 'Recommendation details', with: 'Initial recommendation for a specialist service.'
        replace_product_selection('products_tried_field')
        click_button 'Mark as Completed'
      end
      assert_selector '#submit-report-errors'
      assert_single_action_error('submit-report-errors')
      assert_checked_field 'Outside the catalog'
      assert_field 'Recommendation details', with: 'Initial recommendation for a specialist service.'
      assert_catalog_disabled
      assert_equal '', find('#complete-evaluation-form [role=status]', visible: :all).text(:all)
      take_screenshot('outcome-outside-restored', html: true, full: true)
      within '#complete-evaluation-form' do
        click_button 'Mark as Completed'
      end
      assert_selector '#submit-report-errors'
      assert_single_action_error('submit-report-errors')
      assert_checked_field 'Outside the catalog'
      assert_field 'Recommendation details', with: 'Initial recommendation for a specialist service.'
      assert_catalog_disabled

      within '#complete-evaluation-form' do
        choose 'No suitable product'
        assert_selector '[role=status]', text: I18n.t('evaluators.evaluations.recommendations.feedback.no_suitable_product'), visible: :all
        fill_in 'Appointment Date/Time', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
        fill_in 'Recommendation details', with: 'No suitable product; arrange a specialist assessment.'
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'no_suitable_product', @evaluation.reload.recommendation_outcome
      assert_equal [], @evaluation.products_tried_field
      assert_equal [], @evaluation.recommended_product_ids
      assert_text 'No suitable product; arrange a specialist assessment.'
      take_screenshot('outcome-no-suitable-completed', html: true, full: true)
    end

    test 'noncatalog recommendations are hidden and excluded from submission without JavaScript after rejection' do
      browser = page.driver.browser
      browser.disable_javascript
      %w[outside_catalog no_suitable_product].each do |outcome|
        visit evaluators_evaluation_path(@evaluation)
        assert_no_selector '#complete-evaluation-form input[type=radio]:checked'
        assert_server_catalog_disabled
        fill_report(appointment_time: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'))
        within '#complete-evaluation-form' do
          choose I18n.t("evaluations.recommendation_outcomes.#{outcome}")
          fill_in 'Recommendation details', with: 'Preserved noncatalog recommendation.'
          click_button 'Mark as Completed'
        end
        assert_single_action_error('submit-report-errors')
        assert_checked_field I18n.t("evaluations.recommendation_outcomes.#{outcome}")
        assert_field 'Recommendation details', with: 'Preserved noncatalog recommendation.'
        assert_server_catalog_disabled
        take_screenshot("outcome-#{outcome}-restored-without-js", html: true, full: true)
      end
    ensure
      browser&.page&.command('Emulation.setScriptExecutionDisabled', value: false)
    end

    test 'an outside catalog report records truthful recommendations and optional catalog trials' do
      external_details = 'Recommend a specialist hearing clinic assessment outside this catalog. ' \
                         'https://example.org/accessibility/recommendations/specialist-assessment-resources-and-follow-up-options'
      visit evaluators_evaluation_path(@evaluation)
      fill_report
      within '#complete-evaluation-form' do
        choose 'Outside the catalog'
        fill_in 'Recommendation details', with: external_details
        replace_product_selection('products_tried_field', @product)
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'outside_catalog', @evaluation.reload.recommendation_outcome
      assert_equal [@product.id], @evaluation.products_tried_field
      assert_equal [], @evaluation.recommended_product_ids
      assert_text external_details
      assert_text 'Outcome Trial Device'
      page.current_window.resize_to(375, 812)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 375
      take_screenshot('outcome-external-completed', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'a restored external report can switch to catalog recommendations without losing optional details' do
      visit evaluators_evaluation_path(@evaluation)
      fill_report(appointment_time: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'))
      within '#complete-evaluation-form' do
        choose 'Outside the catalog'
        fill_in 'Recommendation details', with: 'Restored recommendation context.'
        replace_product_selection('products_tried_field')
        click_button 'Mark as Completed'
      end
      assert_selector '#submit-report-errors'
      assert_single_action_error('submit-report-errors')
      assert_checked_field 'Outside the catalog'
      assert_catalog_disabled

      within '#complete-evaluation-form' do
        choose 'Catalog products'
        assert_selector '[role=status]', text: I18n.t('evaluators.evaluations.recommendations.feedback.catalog_products'), visible: :all
        fill_in 'Appointment Date/Time', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
        fill_in 'Recommendation details', with: 'Optional catalog context after retry.'
        replace_product_selection('products_tried_field', @product)
        replace_product_selection('recommended_product_ids', @product)
      end
      assert_selector '#catalog-recommendations-group'
      assert_selector '[data-recommendation-outcome-target="triedRequired"]', visible: true
      assert_no_selector '[data-recommendation-outcome-target="notesRequired"]', visible: true
      assert_equal false, page.evaluate_script('document.getElementById("complete_evaluation_recommendation_notes").required')
      assert_equal 'false', find_field('Recommendation details')['aria-required']
      take_screenshot('outcome-catalog-corrected', html: true, full: true)
      within '#complete-evaluation-form' do
        click_button 'Mark as Completed'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal 'catalog_products', @evaluation.reload.recommendation_outcome
      assert_equal [@product.id], @evaluation.recommended_product_ids
      assert_equal 'Optional catalog context after retry.', @evaluation.recommendation_notes
      take_screenshot('outcome-catalog-completed', html: true, full: true)
    end

    test 'working notes remain separate and editable through rejection replacement refresh and clearing' do
      requested = create(:evaluation, evaluator: @evaluator, status: :requested, evaluation_date: nil)
      original_notes = requested.notes
      visit evaluators_evaluation_path(requested)
      failed_event = Event.new
      failed_event.errors.add(:base, 'Audit record unavailable')
      AuditEventService.stub(:log, ->(**) { raise ActiveRecord::RecordInvalid, failed_event }) do
        within '#working-notes-form' do
          fill_in 'Working notes', with: 'Reached voicemail; try again tomorrow.'
          click_button 'Save working notes'
        end
        assert_selector '#save-working-notes-errors'
        assert_single_action_error('save-working-notes-errors')
      end
      assert_field 'Working notes', with: 'Reached voicemail; try again tomorrow.'
      assert_nil requested.reload.working_notes
      take_screenshot('working-notes-restored', html: true, full: true)

      within '#working-notes-form' do
        fill_in 'Working notes', with: 'Contact person confirmed the appointment arrangements.'
        click_button 'Save working notes'
      end
      assert_text 'Working notes saved.'
      page.refresh
      assert_field 'Working notes', with: 'Contact person confirmed the appointment arrangements.'
      assert_equal 'requested', requested.reload.status
      assert_nil requested.evaluation_date
      assert_equal original_notes, requested.notes
      take_screenshot('working-notes-saved', html: true, full: true)

      within '#working-notes-form' do
        fill_in 'Working notes', with: ''
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
          fill_in 'New Note', with: 'Attempted supplemental follow-up.'
          click_button 'Add Note'
        end
        assert_selector '#supplemental-notes-errors'
        assert_single_action_error('supplemental-notes-errors')
        assert_field 'New Note', with: 'Attempted supplemental follow-up.'
        assert_equal 'supplemental-notes-errors', page.evaluate_script('document.activeElement.id')
        assert_selector '#supplemental_evaluation_post_completion_notes[aria-invalid=true]'
        assert_selector '#supplemental_evaluation_post_completion_notes[aria-describedby="supplemental-notes-post-completion-notes-error"]'
        page.driver.browser.keyboard.type(:tab)
        page.driver.browser.keyboard.type(:enter)
        assert_equal 'supplemental_evaluation_post_completion_notes', page.evaluate_script('document.activeElement.id')
        take_screenshot('supplemental-notes-restored', html: true, full: true)
      ensure
        Evaluation.any_instance.unstub(:update)
        Evaluation.any_instance.unstub(:errors)
      end

      within '#supplemental-notes-form' do
        fill_in 'New Note', with: 'Confirmed supplemental next steps.'
        click_button 'Add Note'
      end
      assert_text 'Evaluation updated successfully.'
      page.refresh
      assert_field 'Update Note', with: 'Confirmed supplemental next steps.'
      assert_equal 'Confirmed supplemental next steps.', completed.reload.post_completion_notes
      take_screenshot('supplemental-notes-saved', html: true, full: true)

      within '#supplemental-notes-form' do
        fill_in 'Update Note', with: ''
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
        choose 'Catalog products'
        replace_product_selection('products_tried_field', @product)
        replace_product_selection('recommended_product_ids')
      end
      styles = page.evaluate_script(<<~JS)
        (() => {
          const style = getComputedStyle(document.querySelector('#complete-evaluation-form input[type=submit]'));
          return {foreground: style.color, background: style.backgroundColor};
        })()
      JS
      assert_operator color_contrast(styles.fetch('foreground'), styles.fetch('background')), :>=, 4.5
      find_field('Evaluation Report Notes').send_keys(:tab)
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
        fill_in 'Evaluation Report Notes', with: 'Appointment observations recorded.'
      end
    end

    def assert_catalog_disabled
      assert_no_selector '#catalog-recommendations-group', visible: true
      assert_selector '#catalog-recommendations-group input[type=checkbox]:disabled', visible: :all
      assert_equal true, page.evaluate_script('document.getElementById("complete_evaluation_recommendation_notes").required')
      assert_equal 'true', find_field('Recommendation details')['aria-required']
    end

    def assert_server_catalog_disabled
      assert_selector '#catalog-recommendations-group[hidden][disabled]', visible: :all
      assert_no_selector '#catalog-recommendations-group', visible: true
      assert_selector '#catalog-recommendations-group input:disabled', visible: :all
      assert_selector '#products-tried-group input[type=checkbox]:not(:disabled)'
      assert_equal false, page.evaluate_script('new FormData(document.getElementById("complete-evaluation-form")).has("evaluation[recommended_product_ids][]")')
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
