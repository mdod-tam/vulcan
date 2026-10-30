# frozen_string_literal: true

require 'test_helper'

class ApplicationAssigneeValidationTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    Current.user = @admin
    @application = create(:application, status: :approved, application_date: Date.current)
  end

  teardown { Current.reset }

  test 'invalid evaluator objects cannot reset an existing cancelled appointment through the canonical writer' do
    evaluation = create(:evaluation, :cancelled, application: @application, constituent: @application.user)
    before = evaluation.attributes
    products = evaluation.recommended_product_ids
    wrong_role = create(:trainer)
    candidates = [nil, build(:evaluator), create(:evaluator, status: :inactive), wrong_role, create(:constituent)]

    candidates.each do |candidate|
      result = nil
      assert_no_difference ['Evaluation.count', 'Notification.count', "Event.where(action: 'evaluator_assigned').count"] do
        assert_no_enqueued_emails do
          result = Applications::EvaluatorAssignment.assign(@application, candidate, actor: @admin)
        end
      end

      assert_predicate result, :failure?
      assert_equal 'Select an active evaluator.', result.message
      assert_equal before, evaluation.reload.attributes
      assert_equal products, evaluation.recommended_product_ids
    end
  end

  test 'staff granted the other discipline can be assigned through the canonical writers' do
    admin = create(:admin)
    Policy.find_or_create_by!(key: 'waiting_period_years').update!(value: 3)
    Policy.find_or_create_by!(key: 'max_training_sessions').update!(value: 3)
    granted_trainer = create(:evaluator)
    create(:role_capability, user: granted_trainer, capability: 'can_train')
    granted_evaluator = create(:trainer)
    create(:role_capability, user: granted_evaluator, capability: 'can_evaluate')

    assert_predicate Applications::TrainerAssignment.assign(@application, granted_trainer, actor: admin), :success?
    assert_predicate Applications::EvaluatorAssignment.assign(@application, granted_evaluator, actor: admin), :success?
    assert_equal granted_trainer, @application.reload.assigned_trainer
    assert_equal granted_evaluator, @application.latest_evaluation.evaluator
  end

  test 'a non-admin or ineligible acting user cannot assign through the canonical writers' do
    evaluator = create(:evaluator)
    trainer = create(:trainer)
    inactive_admin = create(:admin, status: :inactive)

    [create(:constituent), create(:evaluator), inactive_admin, nil].each do |actor|
      result = Applications::EvaluatorAssignment.assign(@application, evaluator, actor: actor)
      assert_predicate result, :failure?
      assert_equal 'Only an administrator can assign an evaluator.', result.message
      result = Applications::TrainerAssignment.assign(@application, trainer, actor: actor)
      assert_predicate result, :failure?
      assert_equal 'Only an administrator can assign a trainer.', result.message
    end
  end

  test 'an ineligible current evaluator is rejected before the reassignment no-op' do
    admin = create(:admin)
    evaluator = create(:evaluator)
    evaluation = create(:evaluation, application: @application, constituent: @application.user, evaluator: evaluator)
    evaluator.update!(status: :inactive)
    before = evaluation.attributes

    result = nil
    assert_no_difference ['Evaluation.count', 'Notification.count', "Event.where(action: 'evaluator_reassigned').count"] do
      assert_no_enqueued_emails do
        result = Applications::EvaluatorAssignment.reassign(@application, evaluator, actor: admin)
      end
    end

    assert_predicate result, :failure?
    assert_equal 'Select an active evaluator.', result.message
    assert_equal before, evaluation.reload.attributes
  end

  test 'invalid trainer objects cannot create sessions through the canonical writer' do
    Policy.find_or_create_by!(key: 'waiting_period_years').update!(value: 3)
    Policy.find_or_create_by!(key: 'max_training_sessions').update!(value: 3)
    wrong_role = create(:evaluator)
    candidates = [nil, build(:trainer), create(:trainer, status: :suspended), wrong_role, create(:constituent)]
    application_attributes = @application.reload.attributes

    candidates.each do |candidate|
      result = nil
      assert_no_difference ['TrainingSession.count', 'Notification.count', 'Event.count'] do
        assert_no_enqueued_jobs do
          result = Applications::TrainerAssignment.assign(@application, candidate, actor: @admin)
        end
      end

      assert_predicate result, :failure?
      assert_equal 'Select an active trainer.', result.message
    end

    assert_equal application_attributes, @application.reload.attributes
  end
end
