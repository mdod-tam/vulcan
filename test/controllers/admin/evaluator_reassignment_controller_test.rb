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

  test 'the panel follows the open evaluation when a newer evaluation is completed' do
    @evaluation.update_columns(created_at: 2.days.ago)
    finished_by = create(:evaluator, first_name: 'Finishedprobe')
    create(:evaluation, :completed, application: @application, constituent: @application.user, evaluator: finished_by)

    get admin_application_path(@application)

    assert_response :success
    assert_select '[data-testid="evaluator-assignment-section"]', text: /Current Evaluator\s+#{Regexp.escape(@evaluator.full_name)}/
    assert_select '[data-testid="evaluator-assignment-section"]', text: /Current Evaluator\s+#{Regexp.escape(finished_by.full_name)}/, count: 0
    assert_select "form[action='#{reassign_evaluator_admin_application_path(@application)}']"
  end

  test 'a cancelled evaluation offers the assignment form that restarts it, not a transfer' do
    @evaluator.update_columns(type: 'Users::Constituent')
    @evaluation.update_columns(status: Evaluation.statuses[:cancelled])

    get admin_application_path(@application)

    assert_response :success
    assert_select '[data-testid="evaluator-assignment-section"]', text: /Cancelled/
    assert_select "form[action='#{reassign_evaluator_admin_application_path(@application)}']", count: 0
    assert_select '[data-testid="evaluator-ineligible-notice"]', count: 0
    assert_select "form[action='#{assign_evaluator_admin_application_path(@application)}'] select[name='evaluator_id']"

    assert_no_difference 'Evaluation.count' do
      post assign_evaluator_admin_application_path(@application), params: { evaluator_id: @replacement.id }
    end

    assert_redirected_to admin_application_path(@application)
    @evaluation.reload
    assert_equal [@replacement.id, 'requested'], [@evaluation.evaluator_id, @evaluation.status]
  end

  test 'non-admin evaluator cannot transfer an assignment' do
    sign_in_for_controller_test(@evaluator)
    post reassign_evaluator_admin_application_path(@application), params: { evaluator_id: @replacement.id }
    assert_redirected_to root_path
    assert_equal @evaluator.id, @evaluation.reload.evaluator_id
  end

  test 'reassignment requires the existing modal confirmation pattern and identifies same-name evaluators' do
    same_name_replacement = create(:evaluator, first_name: @replacement.first_name, last_name: @replacement.last_name)

    get admin_application_path(@application)
    assert_response :success

    assert_select 'button[type=button][data-controller=modal][data-action="click->modal#open"]' \
                  '[data-modal-id=evaluator-reassign-confirm-dialog]', text: 'Reassign Evaluator'
    assert_select 'dialog#evaluator-reassign-confirm-dialog[data-controller=modal][data-action~="cancel->modal#guardCancel"]' \
                  '[aria-labelledby=evaluator-reassign-confirm-heading][aria-describedby=evaluator-reassign-confirm-description]' do
      assert_select 'h3#evaluator-reassign-confirm-heading', text: 'Reassign Evaluator'
      assert_select 'p#evaluator-reassign-confirm-description', text: /#{Regexp.escape(@evaluator.email)}/
      assert_select "form[action='#{reassign_evaluator_admin_application_path(@application)}'][method=post]", count: 1 do
        assert_select 'label[for=reassign_evaluator_id]', text: 'New evaluator (required)'
        assert_select 'select#reassign_evaluator_id[name=evaluator_id][required]' do
          [@replacement, same_name_replacement].each do |person|
            assert_select "option[value='#{person.id}']", text: "#{person.full_name} (#{person.email})"
          end
          assert_select "option[value='#{@evaluator.id}']", count: 0
        end
        assert_select 'button[type=button][data-action="click->modal#close"][autofocus]', text: 'Cancel'
        assert_select 'input[type=submit][value="Confirm reassignment"][data-turbo-submits-with="Reassigning..."]'
      end
    end
    assert_select 'form[action=?]', reassign_evaluator_admin_application_path(@application), count: 1
    assert_select 'noscript p', text: 'Enable JavaScript to confirm evaluator reassignment.'
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
