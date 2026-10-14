# frozen_string_literal: true

require 'test_helper'
require 'active_record/testing/query_assertions'

class ApplicationEquipmentFulfillmentTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    FeatureFlag.disable!(:vouchers_enabled)
    @admin = create(:admin)
  end

  test 'procurement and pending review scopes agree with their instance predicates' do
    approved = create(:application, :approved, :with_all_proofs, equipment_po_sent_at: 1.day.ago)
    tracking = create(:application, :approved, :with_all_proofs, equipment_tracking_number: 'Earlier package')
    bids = create(:application, :approved, :with_all_proofs, equipment_bids_sent_at: 1.day.ago)
    blank = create(:application, :approved, :with_all_proofs, equipment_tracking_number: " \t\n")
    voucher = create(:application, :approved, :with_all_proofs, :voucher_fulfillment, equipment_po_sent_at: 1.day.ago)
    archived = create(:application, :archived, equipment_po_sent_at: 1.day.ago)
    rejected = create(:application, :rejected, equipment_tracking_number: 'Earlier rejected package')
    mapped = create(:application, :approved, :with_all_proofs, equipment_po_sent_at: 1.day.ago)
    create(:equipment_item, application: mapped, purchase_order: nil, withdrawn_at: Time.current)
    decided = create(:application, :approved, :with_all_proofs, equipment_po_sent_at: 1.day.ago)
    EquipmentNeeds::Writer.update!(decided, rows: [], expected_initialized_at: '', actor: @admin, reason: 'Delivered before this system')
    applications = [approved, tracking, bids, blank, voucher, archived, rejected, mapped, decided]

    assert_equal [approved.id, tracking.id], Application.equipment_legacy_review.where(id: applications).order(:id).ids
    eligible_ids = Application.equipment_procurement_eligible.where(id: applications).ids
    review_ids = Application.equipment_legacy_review.where(id: applications).ids
    applications.each do |application|
      assert_equal eligible_ids.include?(application.id), application.equipment_procurement_eligible?
      assert_equal review_ids.include?(application.id), application.equipment_legacy_review?
    end
    assert decided.equipment_legacy_unmapped?
    assert_equal :no_equipment, decided.admin_fulfillment_responsibility_state
    assert_not_equal :legacy_review, archived.admin_fulfillment_responsibility_state
    assert_not_equal :legacy_review, rejected.admin_fulfillment_responsibility_state
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
