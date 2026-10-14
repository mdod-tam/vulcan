# frozen_string_literal: true

require 'test_helper'

module Admin
  class EquipmentFulfillmentSectionTest < ActionDispatch::IntegrationTest
    setup do
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      @application = create(:application, :approved, :with_all_proofs)
    end

    test 'the application separates original recommendations, purchasing needs, and readonly legacy facts' do
      evaluation = create(:evaluation, :completed, application: @application)
      EquipmentNeeds::Writer.initialize_from!(evaluation, actor: @admin)
      @application.update!(equipment_bids_sent_at: Date.new(2026, 9, 9), equipment_po_sent_at: Date.new(2026, 9, 10),
                           equipment_tracking_number: '1Z999AA1')

      get admin_application_path(@application)

      assert_response :success
      assert_select '#equipment' do
        assert_select 'h2', text: 'Original assessment recommendation'
        assert_select 'li', text: /#{Regexp.escape(evaluation.recommended_products.first.name)}/
        assert_select 'h3', text: 'New devices still needed'
        assert_select 'h3', text: 'Actual equipment devices'
        assert_select 'h3', text: 'Earlier fulfillment details'
        assert_select 'dd', text: '1Z999AA1'
        assert_select 'input', count: 0
        assert_select 'form', count: 0
        assert_select 'a[href=?]', edit_admin_application_equipment_needs_path(@application), text: 'Edit equipment needs'
      end

      get evaluators_evaluation_path(evaluation)
      assert_response :success
      assert_select 'input[name^="application[equipment_"]', count: 0
      assert_select 'a', text: 'Edit equipment needs', count: 0
    end

    test 'reading an application without a report or marker does not seed purchasing needs' do
      assert_no_difference(['EquipmentNeed.count', 'EquipmentItem.count', 'Event.count']) do
        get admin_application_path(@application)
      end

      assert_response :success
      assert_select '#equipment', text: /No completed evaluation report is available/
      assert_select '#equipment', text: /Purchasing needs have not been initialized/
      assert_nil @application.reload.equipment_needs_initialized_at
    end

    test 'voucher applications have no equipment purchasing section' do
      @application.update!(fulfillment_type: :voucher)

      get admin_application_path(@application)

      assert_response :success
      assert_select '#equipment', count: 0
    end

    test 'noncatalog outcomes display rationale with an intentional empty initialized needs list' do
      %w[outside_catalog no_suitable_product].each do |outcome|
        application = create(:application, :approved, :with_all_proofs)
        report = build(:evaluation, :completed, application: application, recommendation_outcome: outcome,
                                                recommendation_notes: 'Written specialist recommendation.',
                                                working_notes: 'Internal outreach not part of the submitted report.')
        report.recommended_products = []
        report.products_tried = []
        report.save!
        EquipmentNeeds::Writer.initialize_from!(report, actor: @admin)

        get admin_application_path(application)

        assert_response :success
        assert_select '#equipment', text: /Written specialist recommendation/
        assert_select '#equipment', text: /No new devices are currently needed/
        assert_select '#equipment', text: /No physical device records are currently linked/
        assert_not_includes response.body, report.working_notes
        assert_empty application.equipment_needs
        assert_empty application.equipment_items
        assert application.reload.equipment_needs_initialized_at
      end
    end

    test 'archived applications retain original recommendations, devices, and earlier fulfillment history' do
      evaluation = create(:evaluation, :completed, application: @application)
      EquipmentNeeds::Writer.initialize_from!(evaluation, actor: @admin)
      item = create(:equipment_item, application: @application, product: evaluation.recommended_products.first,
                                     source_evaluation: evaluation, tracking_number: 'Saved device tracking')
      @application.update!(status: :archived, equipment_tracking_number: 'Earlier application tracking')

      get admin_application_path(@application)

      assert_response :success
      assert_select '#equipment', text: /Original assessment recommendation/
      assert_select "#equipment-item-#{item.id}", text: /Saved device tracking/
      assert_select '#equipment', text: /Earlier application tracking/
      assert_select '#equipment a', text: 'Edit equipment needs', count: 0
      assert_select "#equipment-item-#{item.id} a", text: 'Correct device / record shipment'
    end
  end
end
