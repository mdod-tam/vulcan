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

  test 'reassignment rejects missing malformed unavailable and deleted selections without changing the appointment' do
    inactive = create(:evaluator, status: :inactive)
    wrong_role = create(:trainer)
    deleted = create(:evaluator)
    deleted_id = deleted.id
    deleted.destroy!
    missing_id = User.maximum(:id) + 1
    before = @evaluation.attributes

    [nil, '', missing_id, deleted_id, inactive.id, wrong_role.id, "#{@replacement.id}invalid", [@replacement.id]].each do |selected_id|
      assert_no_difference ['Evaluation.count', 'Notification.count', "Event.where(action: 'evaluator_reassigned').count"] do
        assert_no_enqueued_emails do
          post reassign_evaluator_admin_application_path(@application), params: { evaluator_id: selected_id }
        end
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Select an active evaluator.', flash[:alert]
      assert_equal before, @evaluation.reload.attributes
    end
  end

  test 'reassignment handles an evaluator becoming suspended after the form is opened' do
    get admin_application_path(@application)
    assert_select "select[name=evaluator_id] option[value='#{@replacement.id}']"
    @replacement.update!(status: :suspended)
    before = @evaluation.attributes

    assert_no_difference ['Evaluation.count', 'Notification.count', "Event.where(action: 'evaluator_reassigned').count"] do
      assert_no_enqueued_emails do
        post reassign_evaluator_admin_application_path(@application), params: { evaluator_id: @replacement.id }
      end
    end

    assert_redirected_to admin_application_path(@application)
    assert_equal 'Select an active evaluator.', flash[:alert]
    assert_equal before, @evaluation.reload.attributes
  end

  test 'missing application retains its application lookup response during reassignment' do
    post reassign_evaluator_admin_application_path(Application.maximum(:id) + 1), params: { evaluator_id: @replacement.id }
    assert_redirected_to admin_applications_path
  end
end
