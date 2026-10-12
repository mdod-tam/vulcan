# frozen_string_literal: true

require 'test_helper'

class AdminEvaluatorReassignmentControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create(:admin)
    @evaluator = create(:evaluator)
    @replacement = create(:evaluator)
    @application = create(:application, status: :approved, application_date: Date.current, fulfillment_type: :equipment)
    @evaluation = create(:evaluation, application: @application, constituent: @application.user, evaluator: @evaluator)
    sign_in_for_controller_test(@admin)
  end

  test 'admin can transfer through the application workflow without resetting the appointment' do
    date = @evaluation.evaluation_date
    get admin_application_path(@application)
    assert_response :success
    assert_select "form[action='#{reassign_evaluator_admin_application_path(@application)}']"

    post reassign_evaluator_admin_application_path(@application), params: { evaluator_id: @replacement.id }
    assert_redirected_to admin_application_path(@application)
    assert_equal @replacement.id, @evaluation.reload.evaluator_id
    assert_equal date, @evaluation.evaluation_date
    assert @evaluation.status_scheduled?

    sign_in_for_controller_test(@evaluator)
    get evaluators_evaluation_path(@evaluation)
    assert_redirected_to evaluators_evaluations_path

    sign_in_for_controller_test(@replacement)
    get evaluators_evaluation_path(@evaluation)
    assert_response :success
  end

  test 'non-admin evaluator cannot transfer an assignment' do
    sign_in_for_controller_test(@evaluator)
    post reassign_evaluator_admin_application_path(@application), params: { evaluator_id: @replacement.id }
    assert_redirected_to root_path
    assert_equal @evaluator.id, @evaluation.reload.evaluator_id
  end
end
