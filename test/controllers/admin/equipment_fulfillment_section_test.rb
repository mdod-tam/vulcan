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

    test 'the application separates original recommendations, purchasing needs, and actual devices' do
      evaluation = create(:evaluation, :completed, application: @application)
      EquipmentNeeds::Writer.initialize_from!(evaluation, actor: @admin)
      item = create(:equipment_item, application: @application, source_evaluation: evaluation, tracking_number: '1Z999AA1')

      get admin_application_path(@application)

      assert_response :success
      assert_select '#equipment' do
        assert_select 'h3', text: 'Original assessment recommendation'
        assert_select 'li', text: /#{Regexp.escape(evaluation.recommended_products.first.name)}/
        assert_select 'h3', text: 'New devices still needed'
        assert_select 'h3', text: 'Actual equipment devices'
        assert_select "#equipment-item-#{item.id}", text: /1Z999AA1/
        assert_select 'input', count: 0
        assert_select 'form', count: 0
        assert_select 'a[href=?]', edit_admin_application_equipment_needs_path(@application), text: 'Edit equipment needs'
        assert_select '.sr-only', text: 'Fulfillment Status:'
        assert_select 'span.bg-amber-100.text-amber-800', text: /Fulfillment Status:\s*Needs Ordering/
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

    test 'failed HTML proof review still renders current equipment devices' do
      item = create(:equipment_item, application: @application)
      ProofReviewService.any_instance.stubs(:call).returns(BaseService::Result.new(success: false, message: 'Proof review failed.'))

      patch update_proof_status_admin_application_path(@application), params: { proof_type: 'income', status: 'rejected' }

      assert_response :unprocessable_content
      assert_select "#equipment-item-#{item.id} h4", text: /#{Regexp.escape(item.product.name)}/
      assert_select '#equipment span.bg-blue-100.text-blue-800', text: /Fulfillment Status:\s*Ordered/
      assert_select "#equipment-item-#{item.id} span.bg-blue-100.text-blue-800", text: 'Ordered'
    end

    test 'failed application approval still renders current equipment devices' do
      item = create(:equipment_item, application: @application)
      Application.any_instance.stubs(:approve!).returns(false)

      patch approve_admin_application_path(@application)

      assert_response :unprocessable_content
      assert_select "#equipment-item-#{item.id} h4", text: /#{Regexp.escape(item.product.name)}/
      assert_select "#equipment-item-#{item.id} span.bg-blue-100.text-blue-800", text: 'Ordered'
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
        if outcome == 'outside_catalog'
          assert_select '#equipment', text: /An available catalog model has not been selected/
          assert_select '#equipment span.bg-amber-100.text-amber-800', text: /Needs a catalog product/
          assert_select '#equipment', text: /No equipment needed/, count: 0
        else
          assert_select '#equipment', text: /No new devices are currently needed/
          assert_select '#equipment span.bg-gray-100.text-gray-800', text: /No equipment needed/
        end
        assert_select '#equipment', text: /No physical device records are currently linked/
        assert_not_includes response.body, report.working_notes
        assert_empty application.equipment_needs
        assert_empty application.equipment_items
        assert application.reload.equipment_needs_initialized_at
      end
    end

    test 'archived applications retain original recommendations and device history' do
      evaluation = create(:evaluation, :completed, application: @application)
      EquipmentNeeds::Writer.initialize_from!(evaluation, actor: @admin)
      item = create(:equipment_item, application: @application, product: evaluation.recommended_products.first,
                                     source_evaluation: evaluation, tracking_number: 'Saved device tracking')
      @application.transition_status!(:archived, actor: @admin)

      get admin_application_path(@application)

      assert_response :success
      assert_select '#equipment', text: /Original assessment recommendation/
      assert_select "#equipment-item-#{item.id}", text: /Saved device tracking/
      assert_select '#equipment a', text: 'Edit equipment needs', count: 0
      assert_select "#equipment-item-#{item.id} a", text: 'Correct device / record shipment'
    end

    test 'application and shared order histories show named purchasing changes without internal fields' do
      phone = create(:product, manufacturer: 'Audit Maker', name: 'Audit Phone', model_number: 'PHONE-1')
      tablet = create(:product, manufacturer: 'Audit Maker', name: 'Audit Tablet', model_number: 'TABLET-1')
      replacement = create(:product, manufacturer: 'Audit Maker', name: 'Replacement Phone', model_number: 'PHONE-2')
      report = build(:evaluation, :completed, application: @application)
      report.recommended_products = [phone, tablet]
      report.products_tried = [{ 'product_id' => phone.id.to_s, 'reaction' => 'Recorded trial' }]
      report.save!
      EquipmentNeeds::Writer.initialize_from!(report, actor: @admin)
      need = @application.equipment_needs.find_by!(product: phone)
      order = Equipment::Ordering.new(actor: @admin).call(
        needs: [{ id: need.id, lock_version: need.lock_version, quantity: 1 }], items: [],
        purchase_order_attributes: { vendor_id: create(:vendor, business_name: 'Original Supplies').id, number: 'AUDIT-42', sent_at: '09/10/2026' }
      )
      item = order.equipment_items.sole
      acknowledgment = 'Manufacturer confirmed serial reuse.'
      create(:equipment_item, product: create(:product, manufacturer: 'Audit Maker', model_number: 'PHONE-3'), serial_number: 'AUDIT-SERIAL')
      Equipment::Correction.new(actor: @admin).update_item!(
        item: item, attributes: { product_id: replacement.id, carrier: 'fedex', shipped_at: '09/12/2026', tracking_number: 'AUDIT-PACKAGE',
                                  serial_number: 'AUDIT-SERIAL', imei: '123456789012345' },
        expected_version: item.lock_version, reason: 'Correct actual delivered model', serial_duplicate_reason: acknowledgment
      )
      header_attributes = { vendor_id: create(:vendor, business_name: 'Corrected Supplies').id, number: 'UPDATED-42', sent_at: '09/09/2026' }
      item_versions = { item.id.to_s => item.lock_version.to_s }
      Equipment::Correction.new(actor: @admin).update_purchase_order!(
        purchase_order: order, attributes: header_attributes,
        expected_version: order.lock_version, expected_item_versions: item_versions,
        reason: 'Correct vendor reference', confirmed_impact: true,
        impact_token: Equipment::Correction.impact_token(record: order, attributes: header_attributes, extra: { item_versions: item_versions })
      )

      get admin_application_path(@application)
      assert_response :success
      assert_select '#audit-logs' do
        assert_select 'td', text: %r{Purchasing needs: No new devices needed → Audit Maker / Audit Phone / PHONE-1 — 1 device}
        assert_select 'td', text: %r{Audit Maker / Audit Tablet / TABLET-1 — 1 device}
        assert_named_equipment_history(acknowledgment)
        assert_select 'td', text: /Vendor: Original Supplies → Corrected Supplies/
        assert_select 'td', text: /PO number: AUDIT-42 → UPDATED-42/
        assert_select 'td', text: %r{Date PO sent: 09/10/2026 → 09/09/2026}
      end
      assert_select "#equipment-item-#{item.id} details", text: /#{Regexp.escape(acknowledgment)}/
      assert_no_internal_history_fields(css_select('#audit-logs').first.text)

      get admin_purchase_order_path(order)
      assert_response :success
      assert_select 'details', text: /Order and device history/ do
        assert_named_equipment_history(acknowledgment)
      end
      assert_no_internal_history_fields(css_select('details').map(&:text).join)
    end

    private

    def assert_named_equipment_history(acknowledgment)
      assert_select 'p, td', text: %r{Actual catalog product: Audit Maker / Audit Phone / PHONE-1 → Audit Maker / Replacement Phone / PHONE-2}
      assert_select 'p, td', text: %r{Current purchase order: Not recorded → Corrected Supplies / UPDATED-42}
      assert_select 'p, td', text: /Carrier: Not recorded → FedEx/
      assert_select 'p, td', text: %r{Date shipped: Not recorded → 09/12/2026}
      assert_select 'p, td', text: /Serial warning acknowledgment: #{Regexp.escape(acknowledgment)}/
    end

    def assert_no_internal_history_fields(text)
      %w[product_id purchase_order_id lock_version normalized_ manufacturer_model_identity created_at updated_at].each do |field|
        assert_not_includes text, field
      end
      assert_not_includes text, '{'
      assert_not_includes text, '=>'
      assert_not_includes text, 'Id:'
      assert_not_includes text, 'Lock version:'
      assert_not_includes text, 'Created at:'
      assert_not_includes text, 'Updated at:'
    end
  end
end
