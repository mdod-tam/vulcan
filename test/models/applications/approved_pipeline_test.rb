# frozen_string_literal: true

require 'test_helper'
require 'active_record/testing/query_assertions'

module Applications
  class ApprovedPipelineTest < ActiveSupport::TestCase
    include ActiveRecord::Assertions::QueryAssertions

    setup do
      travel_to Time.zone.local(2026, 11, 10, 12)
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @approval = 45.days.ago
    end

    teardown { travel_back }

    test 'equipment groups reuse the fulfillment owner and keep partial work at its earliest unfinished stage' do
      awaiting_order = equipment_application
      create(:equipment_need, application: awaiting_order, remaining_quantity: 2)
      create(:equipment_item, application: awaiting_order, shipped_at: Date.current, tracking_number: 'PARTIAL-SHIPMENT')
      awaiting_tracking = equipment_application
      create(:equipment_item, application: awaiting_tracking)
      create(:equipment_item, application: awaiting_tracking, shipped_at: Date.current, tracking_number: 'PARTIAL-TRACKING')
      recorded = equipment_application
      create(:equipment_item, application: recorded, shipped_at: Date.current, tracking_number: 'RECORDED')

      rows = projection(awaiting_order, awaiting_tracking, recorded).rows.index_by { |row| row.application.id }

      assert_equal :po, rows.fetch(awaiting_order.id).stage
      assert_equal '1 of 3 items ordered · 1 has tracking', rows.fetch(awaiting_order.id).progress
      assert_equal :tracking, rows.fetch(awaiting_tracking.id).stage
      assert_equal '2 of 2 items ordered · 1 has tracking', rows.fetch(awaiting_tracking.id).progress
      assert_equal :recorded, rows.fetch(recorded.id).stage
      assert(rows.values.all? { |row| row.group == :equipment })
    end

    test 'an assigned evaluator waits for a report while an application without one needs assignment' do
      unassigned = equipment_application
      assigned = equipment_application
      evaluation = create(:evaluation, application: assigned)
      log(assigned, 'evaluator_assigned', at: 12.days.ago)
      log(evaluation, 'evaluator_reassigned', at: 2.days.ago, metadata: { application_id: assigned.id })

      rows = projection(unassigned, assigned).rows.index_by { |row| row.application.id }

      assert_equal :evaluator, rows.fetch(unassigned.id).stage
      assert_equal 45, rows.fetch(unassigned.id).days
      assert_equal :report, rows.fetch(assigned.id).stage
      assert_equal evaluation, rows.fetch(assigned.id).evaluation
      assert_equal 12, rows.fetch(assigned.id).days
      assert_equal 'Open evaluation', rows.fetch(assigned.id).action_label
    end

    test 'cancelled evaluator assignment restarts the needs-evaluator clock and reassignment starts report waiting again' do
      application = equipment_application
      evaluation = create(:evaluation, application:, status: :cancelled)
      log(application, 'evaluator_assigned', at: 30.days.ago)
      log(evaluation, 'evaluation_cancelled', at: 9.days.ago, metadata: { application_id: application.id })

      assert_equal 9, projection(application).rows.sole.days

      evaluation.update!(status: :requested)
      log(application, 'evaluator_assigned', at: 4.days.ago)
      log(application, 'evaluator_assigned', at: 2.days.ago)

      row = projection(application).rows.sole
      assert_equal :report, row.stage
      assert_equal 4, row.days
    end

    test 'outside catalog reports require a purchasing decision instead of disappearing as no equipment' do
      application = equipment_application
      report = build(:evaluation, :completed, application:, recommendation_outcome: :outside_catalog,
                                              recommendation_notes: 'Choose a catalog alternative')
      report.recommended_products = []
      report.products_tried = []
      report.save!
      EquipmentNeeds::Writer.initialize_from!(report, actor: @admin)

      row = projection(application).rows.sole

      assert_equal :equipment, row.group
      assert_equal :po, row.stage
      assert_equal 'Review equipment', row.action_label
      assert_equal 'Choose equipment to order', row.progress
    end

    test 'no equipment requires an explicit decision and retains requested training' do
      undecided = equipment_application
      no_equipment = equipment_application(equipment_needs_initialized_at: 10.days.ago, training_requested_at: 5.days.ago)
      log(no_equipment, 'equipment_needs_initialized', at: 10.days.ago)

      rows = projection(undecided, no_equipment).rows.index_by { |row| row.application.id }

      assert_equal :evaluator, rows.fetch(undecided.id).stage
      row = rows.fetch(no_equipment.id)
      assert_equal :none, row.group
      assert_equal :none, row.stage
      assert_equal 10, row.days
      assert_equal 'Open training', row.action_label
      assert_includes row.progress, 'training requested'
    end

    test 'normal ordering and recorded shipments use audit times rather than backdated order and ship dates' do
      application = equipment_application(equipment_needs_initialized_at: 30.days.ago)
      order = create(:purchase_order, sent_at: 25.days.ago.to_date)
      item = create(:equipment_item, application:, purchase_order: order, shipped_at: 10.days.ago.to_date, tracking_number: 'BACKDATED')
      log(application, 'equipment_needs_initialized', at: 30.days.ago)
      log(item.purchase_order, 'equipment_order_recorded', at: 20.days.ago, metadata: { application_ids: [application.id] })
      log(item, 'equipment_item_corrected', at: 3.days.ago,
                                            metadata: { application_ids: [application.id], changes: { shipped_at: { old: nil, new: item.shipped_at.iso8601 } } })

      row = projection(application).rows.sole

      assert_equal :recorded, row.stage
      assert_equal 3, row.days
    end

    test 'partial shipments and ordinary device edits do not reset the awaiting-tracking clock' do
      application = equipment_application(equipment_needs_initialized_at: 30.days.ago)
      item = create(:equipment_item, application:)
      shipped = create(:equipment_item, application:, purchase_order: item.purchase_order, shipped_at: Date.current, tracking_number: 'PARTIAL')
      log(item.purchase_order, 'equipment_order_recorded', at: 20.days.ago, metadata: { application_ids: [application.id] })
      log(shipped, 'equipment_item_corrected', at: 5.days.ago,
                                               metadata: { application_ids: [application.id], changes: { shipped_at: { old: nil, new: shipped.shipped_at.iso8601 } } })
      log(item, 'equipment_item_corrected', at: 1.day.ago,
                                            metadata: { application_ids: [application.id], changes: { serial_number: { old: nil, new: 'RECORDED-SERIAL' } } })

      assert_equal 20, projection(application).rows.sole.days
    end

    test 'ambiguous reopened equipment dates remain unavailable rather than guessing from updated at' do
      application = equipment_application(equipment_needs_initialized_at: 30.days.ago)
      create(:equipment_need, application:, remaining_quantity: 1)
      log(application, 'equipment_needs_initialized', at: 30.days.ago)
      log(application, 'equipment_needs_updated', at: 3.days.ago,
                                                  metadata: { changes: { equipment_needs: { old: [], new: [{ remaining_quantity: 1 }] } } })

      row = projection(application).rows.sole

      assert_equal :po, row.stage
      assert_nil row.entered_at
      assert_nil row.days
    end

    test 'expired positive voucher value is a follow-up even before the expiration job updates status' do
      application = voucher_application
      voucher = create(:voucher, application:, status: :active, issued_at: Policy.voucher_validity_period.ago - 8.days,
                                 remaining_value: 180)

      row = projection(application).rows.sole

      assert_equal 'active', voucher.reload.status
      assert_equal :voucher, row.group
      assert_equal :voucher_expired, row.stage
      assert_equal 8, row.days
      assert_equal 180.to_d, row.remaining_value
      assert_includes row.progress, '$180.00 remaining'
    end

    test 'voucher stages retain missing issued fully-used and cancelled applications without equipment cards' do
      missing = voucher_application
      issued = voucher_application
      create(:voucher, application: issued, issued_at: 7.days.ago, remaining_value: 375)
      used = voucher_application
      create(:voucher, :redeemed, application: used)
      cancelled = voucher_application
      create(:voucher, :cancelled, application: cancelled, issued_at: 1.year.ago)

      pipeline = projection(missing, issued, used, cancelled)
      rows = pipeline.rows.index_by { |row| row.application.id }

      assert_equal :voucher_missing, rows.fetch(missing.id).stage
      assert_equal :voucher_issued, rows.fetch(issued.id).stage
      assert_equal 7, rows.fetch(issued.id).days
      assert_equal :voucher_used, rows.fetch(used.id).stage
      assert_equal :voucher_cancelled, rows.fetch(cancelled.id).stage
      assert_empty pipeline.groups.fetch(:equipment)
      assert_equal 0, pipeline.summaries(:voucher).find { |summary| summary.stage == :voucher_expired }.count
    end

    test 'a voucher marked expired early uses its status event rather than claiming a future expiration has passed' do
      application = voucher_application
      voucher = create(:voucher, application:, status: :expired, issued_at: 2.months.ago, remaining_value: 180)
      log(voucher, 'status_changed_to_expired', at: 2.days.ago)

      row = projection(application).rows.sole

      assert_equal :voucher_expired, row.stage
      assert_equal 2, row.days
      assert_includes row.progress, "expired #{2.days.ago.to_date.to_fs(:long)}"

      Policy.find_or_initialize_by(key: 'voucher_validity_period_months').update!(value: 1, updated_by: @admin)
      assert_equal 2, projection(application).rows.sole.days
    end

    test 'recorded voucher expiration keeps its date when validity settings later change' do
      policy = Policy.find_or_initialize_by(key: 'voucher_validity_period_months')
      policy.update!(value: 6, updated_by: @admin)
      application = voucher_application
      voucher = create(:voucher, application:, issued_at: 8.months.ago, remaining_value: 180)
      expired_at = voucher.expiration_date
      Current.set(user: @admin) { voucher.update!(status: :expired) }
      log(voucher, 'expired', at: Time.current, metadata: { expiration_date: expired_at, remaining_value: voucher.remaining_value })

      [7, 12].each do |months|
        policy.update!(value: months, updated_by: @admin)
        row = projection(application).rows.sole

        assert_equal :voucher_expired, row.stage
        assert_equal ((Time.current - expired_at) / 1.day).floor, row.days
        assert_includes row.progress, "expired #{expired_at.to_date.to_fs(:long)}"
      end
    end

    test 'summaries count applications once and exclude missing dates from oldest and average' do
      early = equipment_application
      recent = equipment_application
      unknown = equipment_application
      create(:equipment_need, application: early)
      create(:equipment_need, application: recent)
      create(:equipment_need, application: unknown)
      log(early, 'equipment_needs_initialized', at: 20.days.ago)
      log(recent, 'equipment_needs_initialized', at: 4.days.ago)

      pipeline = projection(early, recent, unknown)
      summary = pipeline.summaries(:equipment).find { |entry| entry.stage == :po }

      assert_equal 3, summary.count
      assert_equal early.id, summary.oldest.application.id
      assert_equal 12, summary.average_days
      assert_equal 1, summary.unknown_dates
      assert_equal 5, pipeline.summaries(:equipment).length
      assert_no_queries do
        pipeline.rows
        pipeline.groups
        pipeline.summaries(:equipment)
      end
    end

    test 'pipeline preloads its fulfillment inputs without unrelated display associations or later queries' do
      application = equipment_application
      report = create(:evaluation, :completed, application:)
      EquipmentNeeds::Writer.initialize_from!(report, actor: @admin)
      create(:equipment_item, application:)

      pipeline = projection(application)
      row = pipeline.rows.sole
      loaded = row.application
      need = loaded.equipment_needs.first
      source = need.source_evaluation
      item = loaded.equipment_items.first

      assert loaded.association(:equipment_needs).loaded?
      assert loaded.association(:equipment_items).loaded?
      assert need.association(:source_evaluation).loaded?
      assert_not need.association(:product).loaded?
      assert_not source.association(:recommended_products).loaded?
      assert_not source.association(:evaluator).loaded?
      assert_not item.association(:product).loaded?
      assert_not item.association(:purchase_order).loaded?
      assert_no_queries do
        assert_equal :needs_action, loaded.admin_fulfillment_responsibility_state
        assert_equal report.id, loaded.equipment_source_report.id
        assert_equal :po, row.stage
        pipeline.summaries(:equipment)
      end
    end

    test 'an application awaiting its first report does not preload unused fulfillment history' do
      application = equipment_application
      evaluation = create(:evaluation, application:)
      pipeline = projection(application)
      row = pipeline.rows.sole
      loaded = row.application

      assert_equal :report, row.stage
      assert_equal evaluation, row.evaluation
      assert loaded.association(:equipment_needs).loaded?
      assert loaded.association(:equipment_items).loaded?
      assert_not loaded.association(:equipment_needs_events).loaded?
      assert_not loaded.association(:completed_equipment_reports).loaded?
      assert_no_queries do
        assert_equal :pending_evaluation, loaded.admin_fulfillment_responsibility_state
        pipeline.groups
        pipeline.summaries(:equipment)
      end
    end

    private

    def equipment_application(**attributes)
      create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment, created_at: 60.days.ago, **attributes)
    end

    def voucher_application
      create(:application, :approved, :with_all_proofs, :voucher_fulfillment, created_at: 60.days.ago)
    end

    def projection(*applications)
      approved_at = Application.connection.quote(@approval)
      cohort = Application.where(id: applications.map(&:id)).select('applications.*', "#{approved_at}::timestamptz AS current_status_entered_at").order(:id)
      ApprovedPipeline.new(cohort, now: Time.current)
    end

    def log(record, action, at:, metadata: {})
      Event.create!(user: @admin, auditable: record, action:, metadata:, created_at: at)
    end
  end
end
