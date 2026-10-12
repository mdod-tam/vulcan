# frozen_string_literal: true

require 'test_helper'

class EvaluationReassignmentTest < ActiveSupport::TestCase
  setup do
    Policy.find_or_create_by!(key: 'waiting_period_years').update!(value: 3)
    @admin = create(:admin)
    @evaluator = create(:evaluator)
    @replacement = create(:evaluator)
    @application = create(:application, status: :approved, application_date: Date.current)
    @evaluation = create(
      :evaluation,
      application: @application,
      constituent: @application.user,
      evaluator: @evaluator,
      status: :scheduled,
      evaluation_date: 2.days.from_now,
      location: 'Agreed home visit',
      notes: 'Interpreter arrangements'
    )
  end

  test 'transfer preserves the appointment and report context and records both evaluator identities' do
    before = @evaluation.attributes.except('evaluator_id', 'updated_at')
    products = @evaluation.recommended_product_ids

    assert_no_difference('Evaluation.count') do
      assert_difference('Event.where(action: "evaluator_reassigned").count', 1) do
        assert @application.reassign_evaluator!(@replacement, actor: @admin)
      end
    end

    assert_equal @replacement.id, @evaluation.reload.evaluator_id
    assert_equal before, @evaluation.attributes.except('evaluator_id', 'updated_at')
    assert_equal products, @evaluation.recommended_product_ids
    event = Event.find_by!(action: 'evaluator_reassigned', auditable: @evaluation)
    assert_equal @evaluator.id, event.metadata['previous_evaluator_id']
    assert_equal @replacement.id, event.metadata['evaluator_id']
    assert_equal @admin.id, event.user_id
  end

  test 'cancelled and no-show assignments can transfer without losing their outcome history' do
    %i[cancelled no_show].each do |status|
      @evaluation.update!(status: status)
      current = @evaluation.evaluator_id == @replacement.id ? @evaluator : @replacement
      assert @application.reassign_evaluator!(current, actor: @admin)
      assert_equal status.to_s, @evaluation.reload.status
      assert_equal 'Interpreter arrangements', @evaluation.notes
    end
  end

  test 'completed reports cannot transfer' do
    @evaluation.update!(status: :completed, appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)
    assert_not @application.reassign_evaluator!(@replacement, actor: @admin)
    assert_equal @evaluator.id, @evaluation.reload.evaluator_id
    assert @evaluation.status_completed?
  end

  test 'only administrators can transfer to an active evaluator within the service window' do
    assert_not @application.reassign_evaluator!(@replacement, actor: @evaluator)
    @replacement.update!(status: :inactive)
    assert_not @application.reassign_evaluator!(@replacement, actor: @admin)
    assert_equal @evaluator.id, @evaluation.reload.evaluator_id
  end

  test 'audit failure rolls the assignment back' do
    AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(@evaluation))
    assert_not @application.reassign_evaluator!(@replacement, actor: @admin)
    assert_equal @evaluator.id, @evaluation.reload.evaluator_id
  end

  test 'each transfer inside the audit deduplication window retains its actors and both assignments' do
    freeze_time do
      assert_difference('Event.where(action: "evaluator_reassigned", auditable: @evaluation).count', 2) do
        assert @application.reassign_evaluator!(@replacement, actor: @admin)
        assert @application.reassign_evaluator!(@evaluator, actor: @admin)
      end

      events = Event.where(action: 'evaluator_reassigned', auditable: @evaluation).order(:id).to_a
      assert_equal [@admin.id, @admin.id], events.map(&:user_id)
      assert_equal([@evaluator.id, @replacement.id], events.map { |event| event.metadata['previous_evaluator_id'] })
      assert_equal([@replacement.id, @evaluator.id], events.map { |event| event.metadata['evaluator_id'] })
      assert_equal 2, events.map { |event| event.metadata['operation_id'] }.uniq.size

      assert_no_difference('Event.where(action: "evaluator_reassigned", auditable: @evaluation).count') do
        assert @application.reassign_evaluator!(@evaluator, actor: @admin)
      end

      assert_equal @evaluator.id, @evaluation.reload.evaluator_id
    end
  end
end
