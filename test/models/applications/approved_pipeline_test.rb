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

    test 'earliest unfinished stage keeps secondary overdue shipment visible' do
      application = equipment_application(equipment_needs_initialized_at: 40.days.ago)
      need = create(:equipment_need, application:, remaining_quantity: 2, disability_setup_group: nil, unfulfilled_since: 2.days.ago)
      order = create(:purchase_order, sent_at: 35.days.ago.to_date)
      create(:equipment_item, application:, purchase_order: order)

      row = projection(application).rows.sole

      assert_equal :needs_fulfillment, row.stage
      assert_equal [need], Equipment::FulfillmentStage.new(application).requests_to_fulfill
      assert_equal 'Prepare bid', row.action_label
      assert_equal 2, row.days
      assert_equal '0 of 3 units shipped', row.progress
      assert_equal :awaiting_shipment, row.secondary.sole.stage
      assert_equal 1, row.secondary.sole.quantity
      assert_equal order.sent_at.to_time, row.secondary.sole.entered_at
      assert_equal :needs_fulfillment, row.application.admin_fulfillment_responsibility_state
    end

    test 'report waiting uses the current assignment cycle and transfer keeps its clock' do
      unassigned = equipment_application(needs_evaluator_since: 9.days.ago)
      assigned = equipment_application(report_wait_started_at: 12.days.ago)
      evaluation = create(:evaluation, application: assigned, evaluation_date: nil)

      rows = projection(unassigned, assigned).rows.index_by { |row| row.application.id }

      assert_equal :needs_evaluator, rows.fetch(unassigned.id).stage
      assert_equal 9, rows.fetch(unassigned.id).days
      assert_equal :awaiting_report, rows.fetch(assigned.id).stage
      assert_equal evaluation, rows.fetch(assigned.id).evaluation
      assert_equal 12, rows.fetch(assigned.id).days
      assert_equal 'Schedule evaluation', rows.fetch(assigned.id).action_label
      assert_equal 'Evaluator assigned', rows.fetch(assigned.id).progress

      evaluation.update!(evaluation_date: 2.days.from_now, status: :scheduled)
      assert_equal 'View upcoming appointment', projection(assigned.reload).rows.sole.action_label
      assert_equal 'Scheduled', projection(assigned).rows.sole.progress
      evaluation.update!(evaluation_date: 1.day.ago)
      assert_equal 'Enter evaluation report', projection(assigned.reload).rows.sole.action_label
      assert_equal 'Report due', projection(assigned).rows.sole.progress
      evaluation.update!(status: :no_show)
      assert_equal 'Follow up after no-show', projection(assigned.reload).rows.sole.action_label
      assert_equal 'No-show', projection(assigned).rows.sole.progress
    end

    test 'report card preloads the assigned evaluator only for its displayed oldest record' do
      oldest = equipment_application(report_wait_started_at: 12.days.ago)
      newer = equipment_application(report_wait_started_at: 3.days.ago)
      evaluator = create(:evaluator, first_name: 'Morgan', last_name: 'Evaluator')
      create(:evaluation, application: oldest, evaluator:)
      create(:evaluation, application: newer)
      pipeline = projection(oldest, newer)

      card = pipeline.summaries(:equipment).find { |entry| entry.stage == :awaiting_report }

      assert_equal oldest, card.oldest.application
      assert_no_queries { assert_equal 'Morgan Evaluator', card.oldest.evaluation.evaluator.full_name }
      assert_not pipeline.rows.find { |row| row.application.id == newer.id }.evaluation.association(:evaluator).loaded?
    end

    test 'both unresolved report outcomes stay actionable until an explicit empty decision' do
      %i[outside_catalog no_suitable_product].each do |outcome|
        application = equipment_application
        report = build(:evaluation, :completed, application:, recommendation_outcome: outcome,
                                                recommendation_notes: 'Review equipment with staff')
        report.recommended_products = []
        report.products_tried = []
        report.save!
        EquipmentNeeds::Writer.initialize_from!(report, actor: @admin)
        row = projection(application).rows.sole
        assert_equal :needs_fulfillment, row.stage
        assert_equal 'Choose equipment for bid', row.action_label

        application.update!(equipment_needs_decided_at: Time.current)
        row = projection(application).rows.sole
        assert_equal :none, row.group
        assert_equal :no_equipment, row.stage
      end
    end

    test 'unsent PO assignment and sent PO dates are separate stage boundaries' do
      application = equipment_application(equipment_needs_initialized_at: 30.days.ago)
      order = create(:purchase_order, sent_at: nil)
      item = create(:equipment_item, application:, purchase_order: order, po_assigned_at: 6.days.ago)
      assert_equal :ready_to_send_po, projection(application).rows.sole.stage
      assert_equal 6, projection(application).rows.sole.days

      order.update!(sent_at: 3.days.ago.to_date)
      row = projection(application).rows.sole
      assert_equal :awaiting_shipment, row.stage
      assert_equal 3.days.ago.to_date.to_time, row.entered_at

      item.update!(shipped_at: Date.current, tracking_number: 'ACTUAL-SHIPMENT')
      row = projection(application).rows.sole
      assert_equal :awaiting_delivery, row.stage
      assert_equal 'Record delivery', row.action_label
      assert_equal Date.current.to_time, row.entered_at

      item.update!(delivered_on: Date.current)
      row = projection(application).rows.sole
      assert_equal :shipment_recorded, row.stage
      assert_equal '1 of 1 unit delivered', row.progress
    end

    test 'bid reservations count once and use the current line reservation date' do
      application = equipment_application(equipment_needs_initialized_at: 30.days.ago)
      need = create(:equipment_need, application:, remaining_quantity: 3, unfulfilled_since: 30.days.ago)
      group = BidGroup.create!(number: 'MIXED-BID', purpose: 'direct_to_constituents', created_at: 20.days.ago)
      group.bid_group_lines.create!(equipment_need: need, product: need.product, quantity: 3, created_at: 4.days.ago)
      row = projection(application).rows.sole
      assert_equal :awaiting_bid_award, row.stage
      assert_equal 4, row.days
      assert_equal '0 of 3 units shipped', row.progress
      assert_empty row.secondary
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

    test 'summaries count applications once and leave unknown clocks unavailable' do
      early = equipment_application
      recent = equipment_application
      unknown = equipment_application
      create(:equipment_need, application: early, unfulfilled_since: 20.days.ago)
      create(:equipment_need, application: recent, unfulfilled_since: 23.hours.ago)
      create(:equipment_need, application: unknown, unfulfilled_since: nil)

      pipeline = projection(early, recent, unknown)
      summary = pipeline.summaries(:equipment).find { |entry| entry.stage == :needs_fulfillment }
      assert_equal 3, summary.count
      assert_equal early.id, summary.oldest.application.id
      assert_equal 0, pipeline.rows.find { |row| row.application.id == recent.id }.days
      assert_equal 10, summary.average_days
      assert_equal 1, summary.unknown_dates
      assert_equal 8, pipeline.summaries(:equipment).length
      assert_no_queries do
        pipeline.rows
        pipeline.groups
        pipeline.summaries(:equipment)
        pipeline.rows.each { |row| row.application.admin_fulfillment_responsibility_state }
      end
    end

    test 'all stage sorting leaves completed work last and terminal lists newest first' do
      pending = equipment_application
      create(:equipment_need, application: pending, unfulfilled_since: 2.days.ago)
      older = equipment_application
      newer = equipment_application
      create(:equipment_item, application: older, shipped_at: 6.days.ago.to_date, delivered_on: 5.days.ago.to_date, tracking_number: 'OLD', purchase_order: create(:purchase_order, sent_at: 8.days.ago.to_date))
      create(:equipment_item, application: newer, shipped_at: 1.day.ago.to_date, delivered_on: Date.current, tracking_number: 'NEW')
      rows = ApprovedPipeline.sort_rows(projection(older, newer, pending).rows)
      assert_equal([pending.id, newer.id, older.id], rows.map { |row| row.application.id })
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
