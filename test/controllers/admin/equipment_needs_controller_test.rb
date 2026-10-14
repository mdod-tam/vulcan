# frozen_string_literal: true

require 'test_helper'

module Admin
  class EquipmentNeedsControllerTest < ActionDispatch::IntegrationTest
    setup do
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @application = create(:application, :approved, :with_all_proofs)
      @evaluation = create(:evaluation, :completed, application: @application)
      EquipmentNeeds::Writer.initialize_from!(@evaluation, actor: @admin)
      sign_in_for_integration_test(@admin)
    end

    test 'needs editor shows original recommendations and current quantities' do
      get edit_admin_application_equipment_needs_path(@application)

      assert_response :success
      assert_select 'h2', text: 'Original assessment recommendation'
      assert_select 'input[name="equipment_needs[rows][][remaining_quantity]"][value="1"]', count: @application.equipment_needs.count + 1
      assert_select 'input[name="equipment_needs[expected_initialized_at]"]', value: @application.reload.equipment_needs_initialized_at.iso8601(6)
    end

    test 'saving returns to the same equipment tab and filters' do
      parameters = submission
      parameters[:return_context] = { tab: 'needs_ordering', product_id: @evaluation.recommended_product_ids.first, vendor_id: '123' }
      parameters[:equipment_needs][:rows].each { |row| row['remaining_quantity'] = 0 }

      patch admin_application_equipment_needs_path(@application), params: parameters

      assert_redirected_to admin_equipment_index_path(parameters[:return_context])
      assert_empty @application.equipment_needs.remaining
    end

    test 'invalid submission retains quantities, chosen new model, reason, versions, and return context' do
      product = create(:product)
      parameters = submission
      parameters[:equipment_needs][:rows].first['remaining_quantity'] = '2'
      parameters[:equipment_needs][:rows] << { product_id: product.id, remaining_quantity: '0' }
      parameters[:return_context] = { tab: 'needs_ordering', product_id: product.id }

      assert_no_difference('Event.count') { patch admin_application_equipment_needs_path(@application), params: parameters }

      assert_response :unprocessable_entity
      assert_select '[role="alert"]', text: /at least one device/
      assert_select 'input[name="equipment_needs[rows][][remaining_quantity]"][value="2"]'
      assert_select 'select option[selected][value=?]', product.id.to_s
      assert_select 'input[name="equipment_needs[reason]"][value="Changed purchasing needs"]'
      assert_select 'input[name="return_context[product_id]"][value=?]', product.id.to_s
      assert_equal [1], @application.equipment_needs.distinct.pluck(:remaining_quantity)
    end

    test 'constituents cannot view or update purchasing needs' do
      sign_in_for_integration_test(@application.user)

      get edit_admin_application_equipment_needs_path(@application)
      assert_redirected_to root_path
      assert_no_difference('Event.count') { patch admin_application_equipment_needs_path(@application), params: submission }
      assert_redirected_to root_path
    end

    test 'a model archived before save stays selected on its failed form so staff can choose a replacement' do
      product = create(:product, :archived)
      parameters = submission
      parameters[:equipment_needs][:rows] << { product_id: product.id, remaining_quantity: '1' }

      patch admin_application_equipment_needs_path(@application), params: parameters

      assert_response :unprocessable_entity
      assert_select '[role="alert"]', text: /available catalog product/
      assert_select 'select option[selected][value=?]', product.id.to_s
      assert_not @application.equipment_needs.exists?(product: product)
    end

    test 'archived application history stays readable and has no purchasing needs edit link' do
      @application.update!(status: :archived, equipment_po_sent_at: 1.year.ago, equipment_tracking_number: 'Historical tracking')

      get admin_application_path(@application)

      assert_response :success
      assert_select '#equipment h2', text: 'Original assessment recommendation'
      assert_select '#equipment h3', text: 'Earlier fulfillment details'
      assert_select '#equipment', text: /Historical tracking/
      assert_select 'a', text: 'Edit equipment needs', count: 0
    end

    test 'empty initialization keeps its original report visible after a later catalog report' do
      application = create(:application, :approved, :with_all_proofs)
      original = build(:evaluation, :completed, application: application, report_submitted_at: 2.hours.ago,
                                                recommendation_outcome: :no_suitable_product,
                                                recommendation_notes: 'Original assessment found no suitable catalog product.')
      original.recommended_products = []
      original.products_tried = []
      original.save!
      EquipmentNeeds::Writer.initialize_from!(original, actor: @admin)
      marker = application.reload.equipment_needs_initialized_at
      later = create(:evaluation, :completed, application: application)

      [admin_application_path(application), edit_admin_application_equipment_needs_path(application)].each do |path|
        get path

        assert_response :success
        assert_select 'section[aria-labelledby=original-recommendation-title]' do
          assert_select 'p', text: 'No suitable product'
          assert_select 'p', text: original.recommendation_notes
          assert_select 'a[href=?]', evaluators_evaluation_path(original), count: 1
          assert_select 'a[href=?]', evaluators_evaluation_path(later), count: 0
          assert_select 'li', count: 0
        end
      end

      application.update!(status: :archived)
      get admin_application_path(application)

      assert_response :success
      assert_select 'section[aria-labelledby=original-recommendation-title] a[href=?]', evaluators_evaluation_path(original)
      assert_equal marker, application.reload.equipment_needs_initialized_at
      assert_empty application.equipment_needs
    end

    private

    def submission
      {
        equipment_needs: {
          expected_initialized_at: @application.reload.equipment_needs_initialized_at.iso8601(6),
          reason: 'Changed purchasing needs',
          rows: @application.equipment_needs.order(:id).map { |need| need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version') }
        }
      }
    end
  end
end
