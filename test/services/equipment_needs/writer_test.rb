# frozen_string_literal: true

require 'test_helper'
require 'rake'

module EquipmentNeeds
  class WriterTest < ActiveSupport::TestCase
    setup do
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @application = create(:application, :approved, :with_all_proofs)
      @evaluation = create(:evaluation, :completed, application: @application)
    end

    test 'completion initializes one unit per recommendation with provenance and no physical devices' do
      assert_no_difference('EquipmentItem.count') do
        assert_difference('EquipmentNeed.count', @evaluation.recommended_products.size) do
          assert Writer.initialize_from!(@evaluation, actor: @evaluation.evaluator)
        end
      end

      assert @application.reload.equipment_needs_initialized_at
      assert_equal @evaluation.recommended_product_ids.sort, @application.equipment_needs.pluck(:product_id).sort
      assert(@application.equipment_needs.all? { |need| need.remaining_quantity == 1 && need.source_evaluation_id == @evaluation.id })
      event = @application.events.find_by!(action: 'equipment_needs_initialized')
      assert_equal @evaluation.evaluator_id, event.user_id
      assert_equal @evaluation.id, event.metadata['source_evaluation_id']
    end

    test 'initialization and first staff edit only stamp bookkeeping for an invalid historical intake' do
      # Model a persisted risk state; this does not assert that such production records exist.
      @application.update_column(:maryland_resident, false)
      original = @application.reload.attributes.except('equipment_needs_initialized_at', 'updated_at')
      assert_not @application.valid?
      assert_includes @application.errors[:maryland_resident].join, 'Maryland resident'

      assert_raises(ActiveRecord::RecordInvalid) { @application.update!(equipment_needs_initialized_at: Time.current) }
      assert_nil @application.reload.equipment_needs_initialized_at
      assert_difference 'Event.where(action: "equipment_needs_initialized").count', 1 do
        assert Writer.initialize_from!(@evaluation, actor: @evaluation.evaluator)
      end
      assert @application.reload.equipment_needs_initialized_at
      assert_equal original, @application.attributes.except('equipment_needs_initialized_at', 'updated_at')

      staff_application = create(:application, :approved, :with_all_proofs)
      staff_application.update_column(:maryland_resident, false)
      Writer.update!(staff_application, rows: [], expected_initialized_at: '', actor: @admin, reason: 'Reviewed an empty purchasing list')
      assert staff_application.reload.equipment_needs_initialized_at
      assert_equal false, staff_application.maryland_resident
      assert_equal 'approved', staff_application.status
      assert_equal 'equipment_needs_updated', staff_application.events.order(:id).last.action
    end

    test 'catalog replacement and quantity changes leave the submitted report intact' do
      Writer.initialize_from!(@evaluation, actor: @admin)
      original = @evaluation.reload.attributes
      original_products = @evaluation.recommended_product_ids.sort
      replacement = create(:product, name: 'Replacement model')
      rows = submitted_rows.map { |row| row.merge('remaining_quantity' => 0) }
      rows << { 'product_id' => replacement.id, 'remaining_quantity' => 2 }

      assert_difference('EquipmentNeed.count', 1) { edit_needs(rows) }

      assert_equal original, @evaluation.reload.attributes
      assert_equal original_products, @evaluation.recommended_product_ids.sort
      assert_equal 2, @application.equipment_needs.find_by!(product: replacement).remaining_quantity
      assert(@application.equipment_needs.where.not(product: replacement).all? { |need| need.remaining_quantity.zero? })
      event = @application.events.find_by!(action: 'equipment_needs_updated')
      assert_equal 'Family needs a different model', event.metadata['reason']
      assert event.metadata['changes']['equipment_needs']['old'].present?
      assert event.metadata['changes']['equipment_needs']['new'].present?
    end

    test 'an intentional empty needs list survives repeated initialization and a later report' do
      Writer.initialize_from!(@evaluation, actor: @admin)
      edit_needs(submitted_rows.map { |row| row.merge('remaining_quantity' => 0) })
      marker = @application.reload.equipment_needs_initialized_at
      later_report = create(:evaluation, :completed, application: @application)

      assert_no_difference(['EquipmentNeed.count', 'Event.count', 'EquipmentItem.count']) do
        assert_not Writer.initialize_from!(@evaluation, actor: @admin)
        assert_not Writer.initialize_from!(later_report, actor: @admin)
      end
      assert_equal marker, @application.reload.equipment_needs_initialized_at
      assert_empty @application.equipment_needs.remaining
    end

    test 'noncatalog outcomes initialize empty without creating devices' do
      %i[outside_catalog no_suitable_product].each do |outcome|
        application = create(:application, :approved, :with_all_proofs)
        report = build(:evaluation, :completed, application: application, recommendation_outcome: outcome,
                                                recommendation_notes: 'Specialist recommendations')
        report.recommended_products = []
        report.products_tried = []
        report.save!
        assert_no_difference(['EquipmentNeed.count', 'EquipmentItem.count']) do
          assert Writer.initialize_from!(report, actor: @admin)
        end
        assert application.reload.equipment_needs_initialized_at
      end
    end

    test 'an empty draft becomes stale when a report initializes an empty purchasing list' do
      stale_rows = submitted_rows
      stale_marker = @application.equipment_needs_initialized_at&.iso8601(6).to_s
      assert_empty stale_rows
      assert_nil @application.equipment_needs_initialized_at
      report = build(:evaluation, :completed, application: @application, recommendation_outcome: :outside_catalog,
                                              recommendation_notes: 'Outside catalog specialist recommendation')
      report.recommended_products = []
      report.products_tried = []
      report.save!
      original_report = report.reload.attributes
      assert Writer.initialize_from!(report, actor: @admin)
      marker = @application.reload.equipment_needs_initialized_at
      reason = 'Reviewed the recommendation; no new catalog device is needed'

      assert_no_difference(['EquipmentNeed.count', 'EquipmentItem.count', 'Event.count']) do
        assert_raises(Equipment::Conflict) do
          Writer.update!(@application, rows: stale_rows, expected_initialized_at: stale_marker, actor: @admin, reason: reason)
        end
      end
      assert_equal marker, @application.reload.equipment_needs_initialized_at
      assert_equal original_report, report.reload.attributes
      assert_empty @application.equipment_needs
      assert_not @application.equipment_needs_decided?
      assert_equal :needs_catalog_product, @application.admin_fulfillment_responsibility_state

      assert_difference -> { @application.events.where(action: 'equipment_needs_updated').count }, 1 do
        Writer.update!(@application, rows: [], expected_initialized_at: marker.iso8601(6), actor: @admin, reason: reason)
      end
      assert_equal :no_equipment, @application.reload.admin_fulfillment_responsibility_state
      assert_equal reason, @application.events.find_by!(action: 'equipment_needs_updated').metadata['reason']
      assert_equal marker, @application.equipment_needs_initialized_at
      assert_equal original_report, report.reload.attributes
      assert_empty @application.equipment_needs
      assert_no_difference(['EquipmentNeed.count', 'EquipmentItem.count', 'Event.count']) do
        Writer.update!(@application, rows: [], expected_initialized_at: marker.iso8601(6), actor: @admin, reason: reason)
      end
    end

    test 'stale quantity versions reject all changes and emit no successful audit' do
      Writer.initialize_from!(@evaluation, actor: @admin)
      rows = submitted_rows
      need = @application.equipment_needs.order(:id).first
      need.update!(remaining_quantity: 4)
      rows.each { |row| row['remaining_quantity'] = 2 }
      before = @application.equipment_needs.order(:id).pluck(:id, :remaining_quantity, :lock_version)

      assert_no_difference('Event.count') do
        assert_raises(Equipment::Conflict) { edit_needs(rows) }
      end
      assert_equal before, @application.equipment_needs.order(:id).pluck(:id, :remaining_quantity, :lock_version)
    end

    test 'concurrently added rows reject an old complete-list form' do
      Writer.initialize_from!(@evaluation, actor: @admin)
      rows = submitted_rows
      @application.equipment_needs.create!(product: create(:product), remaining_quantity: 1)

      assert_raises(Equipment::Conflict) { edit_needs(rows) }
    end

    test 'an invalid new row rolls back other quantity edits and their audit' do
      Writer.initialize_from!(@evaluation, actor: @admin)
      rows = submitted_rows.map { |row| row.merge('remaining_quantity' => 0) }
      rows << { 'product_id' => create(:product).id, 'remaining_quantity' => -1 }
      before = @application.equipment_needs.pluck(:id, :remaining_quantity, :lock_version)

      assert_no_difference(['EquipmentNeed.count', 'Event.count']) do
        assert_raises(Equipment::Conflict) { edit_needs(rows) }
      end
      assert_equal before, @application.equipment_needs.pluck(:id, :remaining_quantity, :lock_version)
    end

    test 'rapid separate adjustments each retain their audit while a repeated stale save fails' do
      Writer.initialize_from!(@evaluation, actor: @admin)
      first_rows = submitted_rows.map { |row| row.merge('remaining_quantity' => 2) }
      assert_difference('Event.where(action: "equipment_needs_updated").count', 2) do
        edit_needs(first_rows)
        edit_needs(submitted_rows.map { |row| row.merge('remaining_quantity' => 3) })
      end
      assert_no_difference('Event.count') { assert_raises(Equipment::Conflict) { edit_needs(first_rows) } }
    end

    test 'edits require an active administrator, approved equipment, and a reason' do
      Writer.initialize_from!(@evaluation, actor: @admin)
      assert_raises(Equipment::Conflict) { edit_needs(submitted_rows, actor: @evaluation.evaluator) }
      assert_raises(Equipment::Conflict) { edit_needs(submitted_rows, reason: '') }
      @admin.update!(status: :suspended)
      assert_raises(Equipment::Conflict) { edit_needs(submitted_rows) }
      @admin.update!(status: :active)
      @application.update!(status: :archived)
      assert_raises(Equipment::Conflict) { edit_needs(submitted_rows) }
    end

    test 'initialization audit failure rolls back needs and the marker' do
      AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(Event.new))

      assert_no_difference('EquipmentNeed.count') do
        assert_raises(ActiveRecord::RecordInvalid) { Writer.initialize_from!(@evaluation, actor: @admin) }
      end
      assert_nil @application.reload.equipment_needs_initialized_at
    end

    test 'rollout uses report submission order, skips legacy orders, and is idempotent' do
      older_assessment = create(:evaluation, :completed, application: @application, report_submitted_at: 2.hours.ago)
      latest_report = @evaluation
      older_assessment.touch(time: 1.hour.from_now)
      legacy_application = create(:application, :approved, :with_all_proofs, equipment_po_sent_at: 1.day.ago, equipment_tracking_number: 'legacy tracking')
      create(:evaluation, :completed, application: legacy_application)
      run_rollout
      assert_equal latest_report.recommended_product_ids.sort, @application.equipment_needs.pluck(:product_id).sort
      assert(@application.equipment_needs.all? { |need| need.source_evaluation_id == latest_report.id })
      assert_nil legacy_application.reload.equipment_needs_initialized_at
      assert_empty legacy_application.equipment_needs
      edit_needs(submitted_rows.map { |row| row.merge('remaining_quantity' => 0) })
      assert_no_difference(['EquipmentNeed.count', 'Event.count', 'EquipmentItem.count']) { run_rollout }
      assert_empty @application.equipment_needs.remaining
    end

    test 'rollout initializes a completed historical report without inventing its unknown submission time' do
      @evaluation.update_columns(report_submitted_at: nil)
      original_report = @evaluation.reload.attributes

      assert_no_difference('EquipmentItem.count') do
        assert_difference(-> { @application.equipment_needs.count }, @evaluation.recommended_products.size) { run_rollout }
      end

      assert @application.reload.equipment_needs_initialized_at
      assert_equal @evaluation.recommended_product_ids.sort, @application.equipment_needs.pluck(:product_id).sort
      assert_equal [@evaluation.id], @application.equipment_needs.distinct.pluck(:source_evaluation_id)
      assert_equal original_report, @evaluation.reload.attributes
      assert_nil @evaluation.report_submitted_at
      assert_no_difference(['EquipmentNeed.count', 'Event.count', 'EquipmentItem.count']) { run_rollout }
    end

    test 'rollout continues through historical intake validation differences without altering intake fields' do
      @application.update_column(:maryland_resident, false)
      other_application = create(:application, :approved, :with_all_proofs)
      other_report = create(:evaluation, :completed, application: other_application)
      assert_difference 'Event.where(action: "equipment_needs_initialized").count', 2 do
        run_rollout
      end
      assert @application.reload.equipment_needs_initialized_at
      assert_equal false, @application.maryland_resident
      assert other_application.reload.equipment_needs_initialized_at
      assert_equal other_report.recommended_product_ids.sort, other_application.equipment_needs.pluck(:product_id).sort
    end

    test 'bids-only catalog rollout permits an ordinary first PO and preserves the historical date' do
      @application.update!(equipment_bids_sent_at: 2.days.ago)
      bids_date = @application.reload.equipment_bids_sent_at
      run_rollout
      assert @application.reload.equipment_needs_initialized_at
      assert_equal @evaluation.recommended_product_ids.sort, @application.equipment_needs.pluck(:product_id).sort
      assert_equal :needs_action, @application.admin_fulfillment_responsibility_state

      rows = submitted_rows.map { |row| row.slice('id', 'lock_version').merge('quantity' => 1) }
      order = Equipment::Ordering.new(actor: @admin).call(
        needs: rows, items: [], purchase_order_attributes: { vendor_id: create(:vendor).id, number: 'FIRST-AWARD', sent_at: Date.current }
      )
      assert_equal rows.size, order.equipment_items.count
      assert_equal :po_sent, @application.reload.admin_fulfillment_responsibility_state
      assert_equal bids_date, @application.equipment_bids_sent_at
      assert_no_difference(['EquipmentNeed.count', 'EquipmentItem.count', 'Event.count']) { run_rollout }
    end

    test 'first staff confirmation of automatic empty outside catalog needs records the decision once' do
      report = build(:evaluation, :completed, application: @application, recommendation_outcome: :outside_catalog,
                                              recommendation_notes: 'Outside catalog recommendation')
      report.recommended_products = []
      report.products_tried = []
      report.save!
      Writer.initialize_from!(report, actor: @admin)
      original = report.reload.attributes
      marker = @application.reload.equipment_needs_initialized_at
      assert_equal :needs_catalog_product, @application.admin_fulfillment_responsibility_state

      assert_difference -> { @application.events.where(action: 'equipment_needs_updated').count }, 1 do
        edit_needs([], reason: 'Nothing further is required')
      end
      assert_equal :no_equipment, @application.reload.admin_fulfillment_responsibility_state
      assert_equal marker, @application.equipment_needs_initialized_at
      assert_equal 'Nothing further is required', @application.events.find_by!(action: 'equipment_needs_updated').metadata['reason']
      assert_empty @application.equipment_needs
      assert_equal original, report.reload.attributes
      assert_no_difference('Event.count') { edit_needs([], reason: 'Confirm the same decision') }
    end

    test 'failed first empty confirmation retains pending catalog choice and no decision event' do
      report = build(:evaluation, :completed, application: @application, recommendation_outcome: :outside_catalog,
                                              recommendation_notes: 'Outside catalog recommendation')
      report.recommended_products = []
      report.products_tried = []
      report.save!
      Writer.initialize_from!(report, actor: @admin)
      marker = @application.reload.equipment_needs_initialized_at
      AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(Event.new))

      assert_no_difference(['EquipmentNeed.count', 'Event.count']) do
        assert_raises(ActiveRecord::RecordInvalid) { edit_needs([], reason: 'Nothing further is required') }
      end
      assert_equal marker, @application.reload.equipment_needs_initialized_at
      assert_not @application.equipment_needs_decided?
      assert_equal :needs_catalog_product, @application.admin_fulfillment_responsibility_state
    end

    private

    def run_rollout
      Rails.application.load_tasks unless Rake::Task.task_defined?('equipment_needs:initialize')
      task = Rake::Task['equipment_needs:initialize']
      task.reenable
      capture_io { task.invoke(@admin.id) }
    end

    def submitted_rows
      @application.equipment_needs.order(:id).map { |need| need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version') }
    end

    def edit_needs(rows, actor: @admin, reason: 'Family needs a different model')
      Writer.update!(@application, rows: rows, expected_initialized_at: @application.reload.equipment_needs_initialized_at&.iso8601(6).to_s,
                                   actor: actor, reason: reason)
    end
  end
end
