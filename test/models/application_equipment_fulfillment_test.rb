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
    assert_equal :po_sent, application.reload.admin_fulfillment_responsibility_state
    ordered.update!(shipped_at: Date.current, tracking_number: 'Other shipment')
    assert_equal :shipped, application.reload.admin_fulfillment_responsibility_state
    need = create(:equipment_need, application: application)
    assert_equal :needs_action, application.reload.admin_fulfillment_responsibility_state
    need.update!(remaining_quantity: 0)
    ordered.update!(shipped_at: nil, purchase_order: nil)
    assert_equal :needs_action, application.reload.admin_fulfillment_responsibility_state
    assert_equal 'shipped', shipped.queue_status
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
      assert_equal :needs_catalog_product, loaded.sole.admin_fulfillment_responsibility_state
    end
    application.transition_status!(:archived, actor: @admin)
    assert_equal :outside_catalog, application.reload.admin_fulfillment_responsibility_state
  end
end
