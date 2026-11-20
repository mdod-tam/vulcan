# frozen_string_literal: true

require 'test_helper'

module Admin
  class EquipmentFulfillmentSectionTest < ActionDispatch::IntegrationTest
    include IcanconnectTestSupport

    setup do
      start_icanconnect!
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
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
        assert_select 'li', text: /#{Regexp.escape(evaluation.recommended_products.first.catalog_label)}/
        assert_select 'h3', text: 'New devices still needed'
        assert_select 'h3', text: 'Devices for this application'
        assert_select "#equipment-item-#{item.id}", text: /1Z999AA1/
        assert_select "#equipment-item-#{item.id}" do
          assert_select 'dt', text: 'Purchase order'
          assert_select 'dt', text: 'Required setup'
          assert_select 'dt', text: 'Onward destination'
          assert_select 'a.btn.btn-outline', text: 'Edit price and receipt dates'
          assert_select 'a.btn.btn-outline', text: 'Correct device or shipping details'
        end
        assert_select 'input', count: 0
        assert_select 'form', count: 0
        assert_select 'a[href=?]', edit_admin_application_equipment_needs_path(@application), text: 'Edit equipment needs'
        assert_select '.sr-only', text: 'Fulfillment Status:'
        assert_select 'span.badge.badge-warning', text: /Fulfillment Status:\s*Needs bid number/
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
      assert_select '#equipment', text: /Purchasing needs have not been recorded yet/
      assert_nil @application.reload.equipment_needs_initialized_at
    end

    test 'each device names its funding while filing preparation stays on the dashboard' do
      application = approved_deafblind_application
      order = create(:purchase_order, funding_source: 'icanconnect')
      icc = create(:equipment_item, application: application, purchase_order: order, funding_source: 'icanconnect', disability_setup_group: 'deafblind')
      mat = create(:equipment_item, application: application, funding_source: 'mat', disability_setup_group: 'deafblind')

      get admin_application_path(application)

      assert_response :success
      assert_select "#equipment-item-#{icc.id} h4", text: /\(ICC\)/
      assert_select "#equipment-item-#{mat.id} h4", text: /\(MAT\)/
      assert_select '#equipment a[href=?]', admin_icanconnect_filing_prep_path, count: 0

      get admin_dashboard_path
      assert_response :success
      assert_select 'a[href=?]', admin_icanconnect_filing_prep_path
    end

    test 'failed HTML proof review still renders current equipment devices' do
      item = create(:equipment_item, application: @application)
      ProofReviewService.any_instance.stubs(:call).returns(BaseService::Result.new(success: false, message: 'Proof review failed.'))

      patch update_proof_status_admin_application_path(@application), params: { proof_type: 'income', status: 'rejected' }

      assert_response :unprocessable_content
      assert_select "#equipment-item-#{item.id} h4", text: /#{Regexp.escape(item.product.catalog_label)}/
      assert_select '#equipment span.badge.badge-info', text: /Fulfillment Status:\s*Enter shipping info/
      assert_select "#equipment-item-#{item.id} span.badge.badge-info", text: 'Shipping info needed'
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
        assert_select '#equipment', text: /An available catalog model still needs to be selected for this recommendation/
        assert_select '#equipment span.badge.badge-warning', text: /Needs bid number/
        assert_select '#equipment', text: /No equipment needed/, count: 0
        assert_select '#equipment', text: /No devices have been assigned yet/
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
      assert_select "#equipment-item-#{item.id} a", text: 'Correct device or shipping details'
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
      group = Equipment::Bidding.new(actor: @admin).create!(number: 'AUDIT-BID', needs: [{ id: need.id, lock_version: need.lock_version, quantity: 1 }])
      order = Equipment::Ordering.new(actor: @admin).call(
        bid_group: group, expected_version: group.lock_version, application_versions: equipment_bid_profile_versions(group),
        line_versions: group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] }, purchase_order_attributes: { number: 'AUDIT-42' }
      )
      Equipment::Ordering.new(actor: @admin).mark_sent!(order: order, sent_at: '09/10/2026', expected_version: order.lock_version)
      item = order.equipment_items.sole
      acknowledgment = 'Manufacturer confirmed serial reuse.'
      create(:equipment_item, product: create(:product, manufacturer: 'Audit Maker', model_number: 'PHONE-3'), serial_number: 'AUDIT-SERIAL')
      Equipment::Correction.new(actor: @admin).update_item!(
        item: item, attributes: { product_id: replacement.id, carrier: 'fedex', shipped_at: '09/12/2026', tracking_number: 'AUDIT-PACKAGE',
                                  serial_number: 'AUDIT-SERIAL', imei: '123456789012345' },
        expected_version: item.lock_version, reason: 'Correct actual delivered model', serial_duplicate_reason: acknowledgment
      )
      header_attributes = { number: 'UPDATED-42', sent_at: '09/09/2026' }
      item_versions = { item.id.to_s => item.lock_version.to_s }
      Equipment::Correction.new(actor: @admin).update_purchase_order!(
        purchase_order: order, attributes: header_attributes,
        expected_version: order.lock_version, expected_item_versions: item_versions,
        reason: 'Correct PO reference', confirmed_impact: true,
        impact_token: Equipment::Correction.impact_token(record: order, attributes: header_attributes, extra: { item_versions: item_versions })
      )

      assert Event.exists?(auditable: order, action: 'equipment_order_recorded')
      get admin_application_path(@application)
      assert_response :success
      assert_select '#audit-logs' do
        assert_select 'td', text: /Purchasing needs: #{Regexp.escape(phone.catalog_label)} — 1 device/
        assert_select 'td', text: /#{Regexp.escape(tablet.catalog_label)} — 1 device/
        assert_named_equipment_history(acknowledgment, phone:, replacement:)
        assert_select 'td', text: /PO number: AUDIT-42 → UPDATED-42/
        assert_select 'td', text: %r{Date PO sent: 09/10/2026 → 09/09/2026}
      end
      assert_select "#equipment-item-#{item.id} details", text: /#{Regexp.escape(acknowledgment)}/
      assert_no_internal_history_fields(css_select('#audit-logs').first.text)

      get admin_purchase_order_path(order)
      assert_response :success
      assert_select 'details', text: /Order, receipt and device history/ do
        assert_named_equipment_history(acknowledgment, phone:, replacement:)
      end
      assert_no_internal_history_fields(css_select('details').map(&:text).join)
    end

    private

    def assert_named_equipment_history(acknowledgment, phone:, replacement:)
      assert_select 'p, td', text: /Actual catalog product: #{Regexp.escape(phone.catalog_label)} → #{Regexp.escape(replacement.catalog_label)}/
      assert_select 'p, td', text: /Carrier: FedEx/
      assert_select 'p, td', text: %r{Date shipped: 09/12/2026}
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
