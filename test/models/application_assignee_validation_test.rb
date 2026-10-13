# frozen_string_literal: true

require 'test_helper'

class ApplicationAssigneeValidationTest < ActiveSupport::TestCase
  setup do
    @application = create(:application, status: :approved, application_date: Date.current)
  end

  test 'invalid evaluator objects cannot reset an existing cancelled appointment through the canonical writer' do
    evaluation = create(:evaluation, :cancelled, application: @application, constituent: @application.user)
    before = evaluation.attributes
    products = evaluation.recommended_product_ids
    wrong_role = create(:trainer)
    create(:role_capability, user: wrong_role, capability: 'can_evaluate')
    candidates = [nil, build(:evaluator), create(:evaluator, status: :inactive), wrong_role]

    candidates.each do |candidate|
      assert_no_difference ['Evaluation.count', 'Notification.count', "Event.where(action: 'evaluator_assigned').count"] do
        assert_no_enqueued_emails do
          assert_not @application.assign_evaluator!(candidate)
        end
      end

      assert_includes @application.errors[:base], 'Select an active evaluator.'
      assert_equal before, evaluation.reload.attributes
      assert_equal products, evaluation.recommended_product_ids
    end
  end

  test 'an ineligible current evaluator is rejected before the reassignment no-op' do
    admin = create(:admin)
    evaluator = create(:evaluator)
    evaluation = create(:evaluation, application: @application, constituent: @application.user, evaluator: evaluator)
    evaluator.update!(status: :inactive)
    before = evaluation.attributes

    assert_no_difference ['Evaluation.count', 'Notification.count', "Event.where(action: 'evaluator_reassigned').count"] do
      assert_no_enqueued_emails do
        assert_not @application.reassign_evaluator!(evaluator, actor: admin)
      end
    end

    assert_includes @application.errors[:base], 'Select an active evaluator.'
    assert_equal before, evaluation.reload.attributes
  end

  test 'invalid trainer objects cannot create sessions through the canonical writer' do
    Policy.find_or_create_by!(key: 'waiting_period_years').update!(value: 3)
    Policy.find_or_create_by!(key: 'max_training_sessions').update!(value: 3)
    wrong_role = create(:evaluator)
    create(:role_capability, user: wrong_role, capability: 'can_train')
    candidates = [nil, build(:trainer), create(:trainer, status: :suspended), wrong_role]
    application_attributes = @application.reload.attributes

    candidates.each do |candidate|
      assert_no_difference ['TrainingSession.count', 'Notification.count', 'Event.count'] do
        assert_no_enqueued_jobs do
          assert_equal false, @application.assign_trainer!(candidate)
        end
      end

      assert_equal ['Select an active trainer.'], @application.errors[:base]
    end

    assert_equal application_attributes, @application.reload.attributes
  end
end
