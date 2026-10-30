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
    before = @evaluation.attributes.except('evaluator_id', 'updated_at', 'assignment_operation_id')
    previous_operation = @evaluation.assignment_operation_id
    products = @evaluation.recommended_product_ids

    assert_no_difference('Evaluation.count') do
      assert_difference('Event.where(action: "evaluator_reassigned").count', 1) do
        assert_predicate Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @admin), :success?
      end
    end

    assert_equal @replacement.id, @evaluation.reload.evaluator_id
    assert_equal before, @evaluation.attributes.except('evaluator_id', 'updated_at', 'assignment_operation_id')
    assert_equal products, @evaluation.recommended_product_ids
    event = Event.find_by!(action: 'evaluator_reassigned', auditable: @evaluation)
    assert_equal @evaluation.assignment_operation_id, event.metadata['operation_id']
    assert_not_equal previous_operation, @evaluation.assignment_operation_id
    assert_equal @evaluator.id, event.metadata['previous_evaluator_id']
    assert_equal @replacement.id, event.metadata['evaluator_id']
    assert_equal @admin.id, event.user_id
  end

  test 'a no-show assignment is still open and transfers without losing its outcome history' do
    @evaluation.update!(status: :no_show)
    assert_predicate Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @admin), :success?
    assert_equal 'no_show', @evaluation.reload.status
    assert_equal @replacement.id, @evaluation.evaluator_id
    assert_equal 'Interpreter arrangements', @evaluation.notes
  end

  test 'a cancelled assignment is closed and does not transfer' do
    @evaluation.update!(status: :cancelled)
    evaluation_attributes = @evaluation.reload.attributes

    result = nil
    assert_no_difference ['Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @admin)
      end
    end
    assert_predicate result, :failure?

    assert_equal I18n.t('activerecord.errors.models.application.attributes.base.evaluation_assignment_closed'), result.message
    assert_equal evaluation_attributes, @evaluation.reload.attributes
  end

  test 'a historical completed evaluation does not block transfer of a separate open evaluation' do
    create(:evaluation, :completed, application: @application, constituent: @application.user, evaluator: @evaluator)

    assert_predicate Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @admin), :success?
    assert_equal @replacement.id, @evaluation.reload.evaluator_id
    assert_equal [@evaluator.id], @application.evaluations.completed_sessions.pluck(:evaluator_id)
  end

  test 'completed reports cannot transfer' do
    @evaluation.update!(status: :completed, appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)
    evaluation_attributes = @evaluation.reload.attributes
    application_attributes = @application.reload.attributes

    result = nil
    assert_no_difference ['Evaluation.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @admin)
      end
    end
    assert_predicate result, :failure?

    assert_equal I18n.t('activerecord.errors.models.application.attributes.base.evaluation_assignment_closed'), result.message
    assert_equal evaluation_attributes, @evaluation.reload.attributes
    assert_equal application_attributes, @application.reload.attributes
  end

  test 'only administrators can transfer to an active evaluator within the service window' do
    evaluation_attributes = @evaluation.reload.attributes
    application_attributes = @application.reload.attributes

    result = nil
    assert_no_difference ['Evaluation.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @evaluator)
      end
    end
    assert_predicate result, :failure?
    assert_equal I18n.t('activerecord.errors.models.application.attributes.base.evaluation_service_window'), result.message

    @replacement.update!(status: :inactive)
    result = nil
    assert_no_difference ['Evaluation.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @admin)
      end
    end
    assert_predicate result, :failure?
    assert_equal 'Select an active evaluator.', result.message
    assert_equal evaluation_attributes, @evaluation.reload.attributes
    assert_equal application_attributes, @application.reload.attributes
  end

  test 'locked application revalidation rejects an expired service window' do
    stale_application = Application.find(@application.id)
    @application.update!(application_date: 4.years.ago.to_date)
    application_attributes = @application.reload.attributes
    evaluation_attributes = @evaluation.reload.attributes

    result = nil
    assert_no_difference ['Evaluation.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = Applications::EvaluatorAssignment.reassign(stale_application, @replacement, actor: @admin)
      end
    end
    assert_predicate result, :failure?

    assert_equal I18n.t('activerecord.errors.models.application.attributes.base.evaluation_service_window'), result.message
    assert_equal application_attributes, @application.reload.attributes
    assert_equal evaluation_attributes, @evaluation.reload.attributes
  end

  test 'an application without an assignment returns false without creating one' do
    application = create(:application, status: :approved, application_date: Date.current)
    application_attributes = application.reload.attributes

    result = nil
    assert_no_difference ['Evaluation.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = Applications::EvaluatorAssignment.reassign(application, @replacement, actor: @admin)
      end
    end
    assert_predicate result, :failure?

    assert_equal I18n.t('activerecord.errors.models.application.attributes.base.evaluation_assignment_closed'), result.message
    assert_equal application_attributes, application.reload.attributes
  end

  test 'same-assignee transfer completes normally without a write audit or enqueue' do
    evaluation_attributes = @evaluation.reload.attributes
    application_attributes = @application.reload.attributes

    assert_no_difference ['Evaluation.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        assert_predicate Applications::EvaluatorAssignment.reassign(@application, @evaluator, actor: @admin), :success?
      end
    end

    assert_equal evaluation_attributes, @evaluation.reload.attributes
    assert_equal application_attributes, @application.reload.attributes
  end

  test 'evaluation validation failure returns false without changing either record' do
    invalid_evaluation = Evaluation.new
    invalid_evaluation.errors.add(:evaluator, 'is invalid')
    @application.stubs(:open_evaluation).returns(@evaluation)
    @evaluation.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(invalid_evaluation))
    evaluation_attributes = @evaluation.reload.attributes
    application_attributes = @application.reload.attributes

    result = nil
    assert_no_difference ['Evaluation.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @admin)
      end
    end
    assert_predicate result, :failure?

    assert_equal 'Evaluator is invalid', result.message
    assert_equal evaluation_attributes, @evaluation.reload.attributes
    assert_equal application_attributes, @application.reload.attributes
  end

  test 'audit failure rolls the assignment back' do
    invalid_event = Event.new
    invalid_event.errors.add(:base, 'Audit record unavailable')
    AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(invalid_event))
    evaluation_attributes = @evaluation.reload.attributes
    application_attributes = @application.reload.attributes

    result = nil
    assert_no_difference ['Evaluation.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @admin)
      end
    end
    assert_predicate result, :failure?

    assert_equal 'Audit record unavailable', result.message
    assert_equal evaluation_attributes, @evaluation.reload.attributes
    assert_equal application_attributes, @application.reload.attributes
  end

  test 'each transfer inside the audit deduplication window retains its actors and both assignments' do
    freeze_time do
      assert_difference('Event.where(action: "evaluator_reassigned", auditable: @evaluation).count', 2) do
        assert_predicate Applications::EvaluatorAssignment.reassign(@application, @replacement, actor: @admin), :success?
        assert_predicate Applications::EvaluatorAssignment.reassign(@application, @evaluator, actor: @admin), :success?
      end

      events = Event.where(action: 'evaluator_reassigned', auditable: @evaluation).order(:id).to_a
      assert_equal [@admin.id, @admin.id], events.map(&:user_id)
      assert_equal([@evaluator.id, @replacement.id], events.map { |event| event.metadata['previous_evaluator_id'] })
      assert_equal([@replacement.id, @evaluator.id], events.map { |event| event.metadata['evaluator_id'] })
      assert_equal 2, events.map { |event| event.metadata['operation_id'] }.uniq.size

      assert_no_difference('Event.where(action: "evaluator_reassigned", auditable: @evaluation).count') do
        assert_predicate Applications::EvaluatorAssignment.reassign(@application, @evaluator, actor: @admin), :success?
      end

      assert_equal @evaluator.id, @evaluation.reload.evaluator_id
    end
  end
end
