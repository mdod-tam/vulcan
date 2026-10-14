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
