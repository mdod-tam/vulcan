# frozen_string_literal: true

require 'test_helper'
require 'active_record/testing/query_assertions'

class ApplicationEquipmentFulfillmentTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    FeatureFlag.disable!(:vouchers_enabled)
    @admin = create(:admin)
  end

  test 'procurement scope agrees with its instance predicate' do
    approved = create(:application, :approved, :with_all_proofs)
    voucher = create(:application, :approved, :with_all_proofs, :voucher_fulfillment)
    archived = create(:application, :archived)
    rejected = create(:application, :rejected)
    applications = [approved, voucher, archived, rejected]

    eligible_ids = Application.equipment_procurement_eligible.where(id: applications).ids
    assert_equal [approved.id], eligible_ids
    applications.each do |application|
      assert_equal eligible_ids.include?(application.id), application.equipment_procurement_eligible?
    end
  end

  test 'application responsibility aggregates device queue states and remaining needs' do
    application = create(:application, :approved, :with_all_proofs)
    ordered = create(:equipment_item, application: application)
    shipped = create(:equipment_item, application: application, shipped_at: Date.current, tracking_number: 'Current shipment')
    create(:equipment_item, application: application, purchase_order: nil, withdrawn_at: Time.current)
    assert_equal :awaiting_shipment, application.reload.admin_fulfillment_responsibility_state
    ordered.update!(shipped_at: Date.current, tracking_number: 'Other shipment')
    assert_equal :awaiting_delivery, application.reload.admin_fulfillment_responsibility_state
    need = create(:equipment_need, application: application)
    assert_equal :needs_fulfillment, application.reload.admin_fulfillment_responsibility_state
    need.update!(remaining_quantity: 0)
    ordered.update!(shipped_at: nil, purchase_order: nil)
    assert_equal :needs_fulfillment, application.reload.admin_fulfillment_responsibility_state
    assert_equal 'shipped', shipped.queue_status
  end

  test 'shipment routing filters only homogeneous vendor or stock work' do
    application = create(:application, :approved, :with_all_proofs)
    direct = create(:equipment_item, application:)
    assert_equal({ source: 'vendor' }, application.reload.equipment_fulfillment_stage.action_context)

    create(:equipment_item, application:, fulfillment_source: 'existing_stock', purchase_order: nil,
                            stock_received_on: Date.current, stock_allocated_at: Time.current, intake_provenance: 'Verified shelf stock')
    assert_equal({}, application.reload.equipment_fulfillment_stage.action_context)

    direct.update!(shipped_at: Date.current, tracking_number: 'VENDOR-SHIPMENT-COMPLETE')
    assert_equal({ source: 'stock' }, application.reload.equipment_fulfillment_stage.action_context)
  end

  test 'preloaded outside catalog responsibility keeps its original source without per badge queries' do
    application = create(:application, :approved, :with_all_proofs)
    report = build(:evaluation, :completed, application: application, recommendation_outcome: :outside_catalog,
                                            recommendation_notes: 'Outside catalog specialist recommendation')
    report.recommended_products = []
    report.products_tried = []
    report.save!
    EquipmentNeeds::Writer.initialize_from!(report, actor: @admin)
    create(:evaluation, :completed, application: application)
    loaded = Application.where(id: application.id).to_a
    Application.preload_equipment_fulfillment(loaded)

    assert_no_queries do
      assert_equal report.id, loaded.sole.equipment_source_report.id
      assert_equal :needs_fulfillment, loaded.sole.admin_fulfillment_responsibility_state
    end
    application.transition_status!(:archived, actor: @admin)
    assert_equal :needs_fulfillment, application.reload.admin_fulfillment_responsibility_state
  end

  test 'catalog recommendations and stage facts render from preloaded source relations' do
    application = create(:application, :approved, :with_all_proofs)
    report = create(:evaluation, :completed, application: application)
    EquipmentNeeds::Writer.initialize_from!(report, actor: @admin)
    loaded = Application.find(application.id)

    Application.preload_equipment_fulfillment([loaded])

    assert loaded.association(:equipment_source_evaluation).loaded?
    expected_products = report.recommended_products.map(&:id).sort
    assert_no_queries do
      source = loaded.equipment_source_report
      assert_equal report.id, source.id
      assert_equal report.evaluator.full_name, source.evaluator.full_name
      assert_equal expected_products, source.recommended_products.map(&:id).sort
      assert_not loaded.equipment_catalog_product_pending?
      assert_equal :needs_fulfillment, loaded.admin_fulfillment_responsibility_state
    end
  end

  test 'an explicit decision resolves outside catalog work without reading events' do
    application = create(:application, :approved, :with_all_proofs)
    report = build(:evaluation, :completed, application: application, recommendation_outcome: :outside_catalog,
                                            recommendation_notes: 'Specialist recommendation')
    report.recommended_products = []
    report.products_tried = []
    report.save!
    EquipmentNeeds::Writer.initialize_from!(report, actor: @admin)
    create(:equipment_need, application: application, source_evaluation: report, remaining_quantity: 0)
    loaded = Application.find(application.id)
    Application.preload_equipment_fulfillment([loaded])

    assert loaded.association(:equipment_source_evaluation).loaded?
    assert_no_queries do
      assert_equal report.id, loaded.equipment_source_report.id
      assert_equal :needs_fulfillment, loaded.admin_fulfillment_responsibility_state
    end

    application.update!(equipment_needs_decided_at: Time.current)
    loaded = Application.find(application.id)
    Application.preload_equipment_fulfillment([loaded])

    assert_no_queries do
      assert_not loaded.equipment_catalog_product_pending?
      assert_equal :no_equipment, loaded.admin_fulfillment_responsibility_state
    end
  end

  test 'voucher responsibility does not load equipment associations' do
    application = create(:application, :approved, :with_all_proofs, :voucher_fulfillment)
    loaded = Application.find(application.id)

    assert_no_queries do
      Application.preload_equipment_fulfillment([loaded])
      assert_equal :voucher_no_equipment, loaded.admin_fulfillment_responsibility_state
    end
  end

  test 'stage-only preload covers every equipment stage without lazy association queries' do
    expected = Equipment::FulfillmentStage::DEFINITIONS.map(&:key)
    applications = expected.map do |stage|
      attributes = if stage.in?(%i[needs_evaluator awaiting_report])
                     {}
                   else
                     { equipment_needs_initialized_at: Time.current, equipment_needs_decided_at: Time.current }
                   end
      create(:application, :approved, :with_all_proofs, **attributes)
    end
    create(:evaluation, application: applications[1])
    create(:equipment_need, application: applications[2])
    reserved = create(:equipment_need, application: applications[3])
    group = BidGroup.create!(number: 'STAGE-PRELOAD-BID', purpose: 'direct_to_constituents')
    group.bid_group_lines.create!(equipment_need: reserved, product: reserved.product, quantity: 1)
    create(:equipment_item, application: applications[4], purchase_order: create(:purchase_order, sent_at: nil))
    create(:equipment_item, application: applications[5])
    create(:equipment_item, application: applications[6], shipped_at: Date.current, tracking_number: 'PRELOADED-SHIPMENT')
    create(:equipment_item, application: applications[7], shipped_at: Date.current, delivered_on: Date.current, tracking_number: 'PRELOADED-DELIVERY')
    loaded = Application.where(id: applications).order(:id).to_a

    Application.preload_equipment_fulfillment(loaded, include_display_details: false)

    assert_no_queries do
      assert_equal(expected, loaded.map { |application| application.equipment_fulfillment_stage.stage })
    end
    loaded.each_with_index do |application, index|
      assert_equal index < 2, application.association(:open_equipment_evaluations).loaded?
      assert_not application.association(:equipment_source_evaluation).loaded?
    end
    unreserved_need = loaded[2].equipment_needs.sole
    reserved_need = loaded[3].equipment_needs.sole
    assert unreserved_need.association(:product).loaded?
    assert_not reserved_need.association(:product).loaded?
    [unreserved_need, reserved_need].each { |need| assert_not need.association(:source_evaluation).loaded? }
  end

  test 'stage-only preload keeps unresolved report and detached device actions query-free' do
    unresolved = create(:application, :approved, :with_all_proofs)
    report = build(:evaluation, :completed, application: unresolved, recommendation_outcome: :outside_catalog,
                                            recommendation_notes: 'Review an alternative device')
    report.recommended_products = []
    report.products_tried = []
    report.save!
    EquipmentNeeds::Writer.initialize_from!(report, actor: @admin)
    create(:equipment_need, application: unresolved, source_evaluation: report, remaining_quantity: 0)
    detached = create(:equipment_item, purchase_order: nil)
    loaded = Application.where(id: [unresolved.id, detached.application_id]).order(:id).to_a

    Application.preload_equipment_fulfillment(loaded, include_display_details: false)

    assert_no_queries do
      assert_equal(['Choose equipment for bid', 'Enter bid number'], loaded.map { |application| application.equipment_fulfillment_stage.action })
    end
    assert loaded.first.association(:equipment_source_evaluation).loaded?
    assert_not loaded.first.equipment_needs.sole.association(:product).loaded?
    assert_not loaded.first.equipment_needs.sole.association(:source_evaluation).loaded?
    assert loaded.last.equipment_items.sole.association(:product).loaded?
  end
end
