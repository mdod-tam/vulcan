# frozen_string_literal: true

require 'application_system_test_case'

module Evaluators
  class CatalogSelectionTest < ApplicationSystemTestCase
    test 'assigned evaluator discovers another group and retries a report without losing choices or shipping confirmation' do
      evaluator = create(:evaluator)
      product = create(:product, name: 'Braille Report Device', eligible_disability_groups: ['deafblind'])
      evaluation = create(:evaluation, evaluator: evaluator, status: :scheduled, evaluation_date: 2.days.from_now)
      evaluation.update!(products_tried: [], recommended_product_ids: [])
      system_test_sign_in(evaluator, bypass_mfa_enrollment: true)
      visit evaluators_evaluation_path(evaluation)
      within '#complete-evaluation-form' do
        assert_selector "#trial-#{product.id}-reaction[disabled]", visible: :all
        assert_no_selector "input[name='evaluation[recommended_product_ids][]'][value='#{product.id}']"
        check 'Show all active products'
        find("input[name='evaluation[recommended_product_ids][]'][value='#{product.id}']").check
        find_by_id('report-program-group-deafblind').check
        find("#trial-#{product.id}").check
        select 'Neutral', from: "trial-#{product.id}-reaction"
        fill_in 'Appointment date and time', with: 1.day.from_now.strftime('%Y-%m-%dT%H:%M')
        fill_in 'Location', with: 'Accessible library'
        fill_in 'Report internal notes', with: 'Report observations retained after retry.'
        find('summary', text: 'Default equipment shipping address').click
        fill_in 'Care of', with: 'Confirmed household recipient'
        fill_in 'Address 1', with: '456 Confirmed Avenue'
        check 'Use this confirmed address for equipment shipments'
        click_button 'Submit completed report'
      end
      assert_selector '#submit-report-errors'
      within '#complete-evaluation-form' do
        assert_selector '#report-program-group-deafblind:checked'
        assert_no_text '(invalid group)'
        assert_selector "#trial-#{product.id}:checked"
        assert_selector :select, 'Satisfaction with Braille Report Device', selected: 'Neutral'
        assert_field 'Report internal notes', with: 'Report observations retained after retry.'
        find('summary', text: 'Default equipment shipping address').click
        assert_field 'Address 1', with: '456 Confirmed Avenue'
        assert_checked_field 'Use this confirmed address for equipment shipments'
      end
      take_screenshot('catalog-groups-trial-shipping-restored', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('catalog-groups-trial-shipping-restored-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 800)
      within '#complete-evaluation-form' do
        find("#trial-#{product.id}").uncheck
        assert_selector "#trial-#{product.id}-reaction[disabled]", visible: :all
        find("#trial-#{product.id}").check
        assert_selector :select, 'Satisfaction with Braille Report Device', selected: 'Neutral'
        fill_in 'Appointment date and time', with: 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
        click_button 'Submit completed report'
      end
      assert_text 'Evaluation submitted successfully.'
      assert_equal %w[deaf deafblind], evaluation.application.reload.program_disability_groups
      assert_equal '456 Confirmed Avenue', evaluation.application.shipping_address_1
      assert_equal [product.id], evaluation.reload.recommended_product_ids
      assert_equal 'completed', evaluation.status
      take_screenshot('catalog-confirmed-report-completed', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end
  end
end
