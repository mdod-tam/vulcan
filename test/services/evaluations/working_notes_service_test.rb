# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class WorkingNotesServiceTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @evaluator = create(:evaluator)
      @admin = create(:admin)
      @application = create(:application, status: :approved, application_date: Date.current)
      @evaluation = create(
        :evaluation,
        evaluator: @evaluator,
        application: @application,
        constituent: @application.user,
        status: :scheduled,
        evaluation_date: 2.days.from_now
      )
      clear_enqueued_jobs
    end

    test 'saving working notes leaves appointment report products and application unchanged and sends nothing' do
      original_evaluation = @evaluation.attributes.except('working_notes', 'updated_at')
      original_application = @application.reload.attributes
      original_recommendations = @evaluation.recommended_product_ids
      narrative = 'Left a voicemail; call again next week'

      assert_no_enqueued_jobs do
        assert_difference('Event.where(action: "evaluation_working_notes_updated").count', 1) do
          result = WorkingNotesService.new(
            @evaluation,
            @evaluator,
            { working_notes: narrative, status: 'completed', evaluation_date: 1.day.ago,
              notes: 'Do not replace the report', recommended_product_ids: [] }
          ).call

          assert result.success?
          assert_equal 'Working notes saved.', result.message
        end
      end

      @evaluation.reload
      assert_equal narrative, @evaluation.working_notes
      assert_equal original_evaluation, @evaluation.attributes.except('working_notes', 'updated_at')
      assert_equal original_application, @application.reload.attributes
      assert_equal original_recommendations, @evaluation.recommended_product_ids

      event = Event.find_by!(action: 'evaluation_working_notes_updated', auditable: @evaluation)
      assert_equal @evaluator.id, event.user_id
      assert_equal @evaluation.id, event.metadata['evaluation_id']
      assert_equal @application.id, event.metadata['application_id']
      assert_equal false, event.metadata['cleared']
      assert event.metadata['operation_id'].present?
      assert_not_includes event.metadata.to_json, narrative
    end

    test 'requested work accepts outreach notes without scheduling an appointment' do
      @evaluation.update!(status: :requested, evaluation_date: nil)

      result = WorkingNotesService.new(@evaluation, @evaluator, { working_notes: 'No answer on first contact attempt' }).call

      assert result.success?
      @evaluation.reload
      assert_equal 'requested', @evaluation.status
      assert_nil @evaluation.evaluation_date
      assert_nil @evaluation.report_submitted_at
      assert_equal 'No answer on first contact attempt', @evaluation.working_notes
    end

    test 'another evaluator and an unassigned administrator cannot save working notes' do
      [create(:evaluator), @admin].each do |actor|
        assert_no_difference('Event.where(action: "evaluation_working_notes_updated").count') do
          result = WorkingNotesService.new(@evaluation, actor, { working_notes: 'Unauthorized note' }).call

          assert result.failure?
        end

        assert_nil @evaluation.reload.working_notes
      end
    end

    test 'an administrator assigned as evaluator can save working notes' do
      @evaluation.update!(evaluator: @admin)

      result = WorkingNotesService.new(@evaluation, @admin, { working_notes: 'Admin evaluator outreach note' }).call

      assert result.success?
      assert_equal 'Admin evaluator outreach note', @evaluation.reload.working_notes
      event = Event.find_by!(action: 'evaluation_working_notes_updated', auditable: @evaluation)
      assert_equal @admin.id, event.user_id
    end

    test 'stale former assignee cannot save after an assignment transfer' do
      stale_evaluation = Evaluation.find(@evaluation.id)
      replacement = create(:evaluator)
      assert_predicate Applications::EvaluatorAssignment.reassign(@application, replacement, actor: @admin), :success?

      assert_no_difference('Event.where(action: "evaluation_working_notes_updated").count') do
        result = WorkingNotesService.new(stale_evaluation, @evaluator, { working_notes: 'Stale note' }).call

        assert result.failure?
      end

      assert_nil @evaluation.reload.working_notes
      assert_equal replacement.id, @evaluation.evaluator_id
    end

    test 'stale working-note save cannot change a completed report' do
      stale_evaluation = Evaluation.find(@evaluation.id)
      @evaluation.update!(status: :completed, appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)
      completed_record = @evaluation.attributes

      assert_no_difference('Event.where(action: "evaluation_working_notes_updated").count') do
        result = WorkingNotesService.new(stale_evaluation, @evaluator, { working_notes: 'Too late to change working notes' }).call

        assert result.failure?
      end

      assert_equal completed_record, @evaluation.reload.attributes
    end

    test 'audit failure rolls back the working-note write' do
      @evaluation.update!(working_notes: 'Previously saved note')
      original_record = @evaluation.attributes
      invalid_event = Event.new
      failing_audit = ->(**_attributes) { raise ActiveRecord::RecordInvalid, invalid_event }

      assert_no_enqueued_jobs do
        assert_no_difference('Event.where(action: "evaluation_working_notes_updated").count') do
          AuditEventService.stub(:log, failing_audit) do
            result = WorkingNotesService.new(@evaluation, @evaluator, { working_notes: 'Replacement that must roll back' }).call

            assert result.failure?
          end
        end
      end

      assert_equal original_record, @evaluation.reload.attributes
    end

    test 'clearing working notes records the clear without retaining the narrative in audit metadata' do
      @evaluation.update!(working_notes: 'Temporary outreach note')

      assert_difference('Event.where(action: "evaluation_working_notes_updated").count', 1) do
        result = WorkingNotesService.new(@evaluation, @evaluator, { working_notes: '  ' }).call

        assert result.success?
      end

      assert_nil @evaluation.reload.working_notes
      event = Event.find_by!(action: 'evaluation_working_notes_updated', auditable: @evaluation)
      assert_equal true, event.metadata['cleared']
      assert_not_includes event.metadata.to_json, 'Temporary outreach note'
    end

    test 'unchanged notes are a successful no-op without another audit or job' do
      @evaluation.update!(working_notes: 'Same note')
      original_record = @evaluation.attributes

      assert_no_enqueued_jobs do
        assert_no_difference('Event.where(action: "evaluation_working_notes_updated").count') do
          result = WorkingNotesService.new(@evaluation, @evaluator, { working_notes: 'Same note' }).call

          assert result.success?
        end
      end

      assert_equal original_record, @evaluation.reload.attributes
    end

    test 'distinct rapid saves retain both audit events while identical retries do not add one' do
      freeze_time do
        assert_difference('Event.where(action: "evaluation_working_notes_updated", auditable: @evaluation).count', 2) do
          assert WorkingNotesService.new(@evaluation, @evaluator, { working_notes: 'First outreach attempt' }).call.success?
          assert WorkingNotesService.new(@evaluation, @evaluator, { working_notes: 'Second outreach attempt' }).call.success?
        end

        assert_no_difference('Event.where(action: "evaluation_working_notes_updated", auditable: @evaluation).count') do
          assert WorkingNotesService.new(@evaluation, @evaluator, { working_notes: 'Second outreach attempt' }).call.success?
        end

        assert_equal 'Second outreach attempt', @evaluation.reload.working_notes
        events = Event.where(action: 'evaluation_working_notes_updated', auditable: @evaluation)
        assert_equal 2, events.map { |event| event.metadata['operation_id'] }.uniq.size
      end
    end

    test 'working notes remain available to the replacement evaluator after reassignment' do
      initial_result = WorkingNotesService.new(@evaluation, @evaluator, { working_notes: 'Interpreter and contact arrangements' }).call
      assert initial_result.success?
      replacement = create(:evaluator)

      assert_predicate Applications::EvaluatorAssignment.reassign(@application, replacement, actor: @admin), :success?
      assert_equal 'Interpreter and contact arrangements', @evaluation.reload.working_notes

      result = WorkingNotesService.new(@evaluation, replacement, { working_notes: 'Replacement confirmed interpreter arrangements' }).call

      assert result.success?
      assert_equal 'Replacement confirmed interpreter arrangements', @evaluation.reload.working_notes
      event = Event.where(action: 'evaluation_working_notes_updated', auditable: @evaluation).order(:id).last
      assert_equal replacement.id, event.user_id
    end
  end
end
