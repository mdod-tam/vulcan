# frozen_string_literal: true

require 'test_helper'

class EvaluatorEvaluationAccessTest < ActionDispatch::IntegrationTest
  setup do
    @evaluator = create(:evaluator)
    @admin = create(:admin)
    @evaluation = create(:evaluation, evaluator: @evaluator)
    @application = @evaluation.application
    @application.update!(alternate_contact_name: 'Evaluation Support Person',
                         alternate_contact_email: 'support-person@example.com',
                         alternate_contact_phone: '2025550123',
                         income_details: 'Private financial explanation')
    sign_in_for_controller_test(@evaluator)
  end

  test 'assigned evaluator sees assessment context without financial or administrative details' do
    get evaluators_evaluation_path(@evaluation)
    assert_response :success
    assert_select "a[href='#{application_details_evaluators_evaluation_path(@evaluation)}']"
    assert_select "a[href='#{admin_application_path(@application)}']", count: 0

    get application_details_evaluators_evaluation_path(@evaluation)
    assert_response :success
    assert_includes response.body, @evaluation.constituent.full_name
    assert_includes response.body, @evaluation.constituent.physical_address_1
    assert_includes response.body, 'Evaluation Support Person'
    assert_includes response.body, 'support-person@example.com'
    assert_includes response.body, '2025550123'
    assert_includes response.body, 'Disabilities'
    assert_not_includes response.body, 'Private financial explanation'
    assert_not_includes response.body, 'Annual Income'
    assert_select 'main form', count: 0
  end

  test 'an evaluator cannot read assessment context for another assignment or the admin application' do
    other = create(:evaluation)
    get application_details_evaluators_evaluation_path(other)
    assert_redirected_to evaluators_evaluations_path
    assert_not_includes response.body, other.constituent.full_name

    get admin_application_path(@application)
    assert_redirected_to root_path
  end

  test 'admins who evaluate retain full admin access and assignment-scoped mutation controls' do
    @evaluation.update!(evaluator: @admin)
    sign_in_for_controller_test(@admin)

    get evaluators_evaluation_path(@evaluation)
    assert_response :success
    assert_select "a[href='#{admin_application_path(@application)}']", text: 'View Full Application Details'
    assert_includes response.body, 'Mark Evaluation as Completed'

    get application_details_evaluators_evaluation_path(@evaluation)
    assert_redirected_to admin_application_path(@application)

    get admin_application_path(@application)
    assert_response :success
    assert_includes response.body, 'Private financial explanation'
  end

  test 'standalone creation editing deletion and information-request writes have no route' do
    [[:post, '/evaluators/evaluations'],
     [:get, "/evaluators/evaluations/#{@evaluation.id}/edit"],
     [:delete, "/evaluators/evaluations/#{@evaluation.id}"],
     [:post, "/evaluators/evaluations/#{@evaluation.id}/request_additional_info"]].each do |method, path|
      assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path(path, method: method) }
    end
  end

  test 'supplemental notes cannot be saved before report submission' do
    patch evaluators_evaluation_path(@evaluation), params: { evaluation: { post_completion_notes: 'Unsubmitted supplement' } }

    assert_response :unprocessable_content
    assert_nil @evaluation.reload.post_completion_notes
  end

  test 'supplemental notes are refused when evaluation access is revoked after the request was authorized' do
    holder = create(:trainer)
    create(:role_capability, user: holder, capability: 'can_evaluate')
    evaluation = create(:evaluation, :completed, evaluator: holder)
    sign_in_for_controller_test(holder)
    constructor = Evaluations::SupplementalNotesService.method(:new)
    revoke_before_service = lambda do |*arguments|
      revoked = Users::CapabilityWriter.call(actor: @admin, user: holder, intent: Users::CapabilityWriter::Intent.revoke('can_evaluate'),
                                             operation_id: SecureRandom.uuid, confirmation: nil)
      assert revoked.changed?, revoked.message
      constructor.call(*arguments)
    end

    Evaluations::SupplementalNotesService.stub(:new, revoke_before_service) do
      patch evaluators_evaluation_path(evaluation), params: { evaluation: { post_completion_notes: 'Written after revocation' } }
    end

    assert_response :unprocessable_content
    assert_nil evaluation.reload.post_completion_notes
  end

  test 'a request overtaken by reassignment cannot render the former evaluator contact details' do
    @evaluation.update!(status: :requested, evaluation_date: nil)
    replacement = create(:evaluator)
    constructor = Evaluations::ScheduleService.method(:new)
    reassign_before_service = lambda do |*arguments|
      @evaluation.update!(evaluator: replacement)
      constructor.call(*arguments)
    end

    Evaluations::ScheduleService.stub(:new, reassign_before_service) do
      post schedule_evaluators_evaluation_path(@evaluation), params: {
        evaluation: { evaluation_date: 2.days.from_now, location: 'Library' }
      }
    end

    assert_redirected_to evaluators_evaluations_path
    assert_not_includes response.body, @evaluation.constituent.full_name
    assert_not_includes response.body, 'Evaluation Support Person'
    assert_not @evaluation.reload.status_scheduled?
  end
end
