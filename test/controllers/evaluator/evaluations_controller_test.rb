# frozen_string_literal: true

require 'test_helper'

# This is a controller test for the Evaluators::EvaluationsController
class EvaluationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @evaluator = create(:evaluator)
    @other_evaluator = create(:evaluator)
    @admin = create(:admin)
    sign_in_for_controller_test(@evaluator)
    @product = create(:product, name: 'iPad Air')
    @evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled)
    @requested_evaluation = create(:evaluation, evaluator: @evaluator, status: :requested, evaluation_date: nil, location: nil)
  end

  test 'gets pending' do
    get pending_evaluators_evaluations_path
    assert_response :success
  end

  test 'gets completed' do
    get completed_evaluators_evaluations_path
    assert_response :success
  end

  test 'submits report' do
    assert_difference('Event.where(action: "evaluation_completed").count', 1) do
      assert_changes '@evaluation.reload.status', from: 'scheduled', to: 'completed' do
        post submit_report_evaluators_evaluation_path(@evaluation), params: {
          evaluation: {
            needs: 'Final needs assessment',
            notes: 'Final evaluation notes',
            location: 'Final location',
            evaluation_date: Time.current,
            recommended_product_ids: [@product.id],
            products_tried: [{
              product_id: @product.id,
              reaction: 'Positive'
            }],
            attendees: [{
              name: 'Test User',
              relationship: 'Self'
            }]
          }
        }
      end
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
  end

  test 'show renders evaluation activity and application fulfillment labels' do
    Event.create!(
      user: @evaluator,
      action: 'evaluation_scheduled',
      auditable: @evaluation,
      metadata: { evaluation_id: @evaluation.id, evaluation_date: @evaluation.evaluation_date.iso8601 }
    )
    Event.create!(
      user: @admin,
      action: 'equipment_bids_sent',
      auditable: @evaluation.application,
      metadata: { date: Date.current }
    )

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, 'Activity History'
    assert_includes @response.body, 'Evaluation Scheduled'
    assert_includes @response.body, 'Equipment Bids Sent'
    assert_includes @response.body, 'Application Fulfillment'
  end

  test 'show renders free text attendees without inferred relationship fallback' do
    @evaluation.update!(attendees: [{ 'name' => 'family friend', 'relationship' => 'Not specified' }])

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, 'family friend'
    assert_not_includes @response.body, 'family friend -'
    assert_not_includes @response.body, 'family friend - Not specified'
  end

  test 'assigned evaluator can schedule an evaluation' do
    assert_difference('Event.where(action: "evaluation_scheduled").count', 1) do
      post schedule_evaluators_evaluation_path(@requested_evaluation),
           params: { evaluation_date: 2.days.from_now, location: 'Library', notes: 'Scheduled by evaluator' }
    end

    assert_redirected_to evaluators_evaluation_path(@requested_evaluation)
    assert_equal 'scheduled', @requested_evaluation.reload.status
    assert_equal 'Library', @requested_evaluation.location
  end

  test 'admin can view evaluation but only in read-only mode' do
    sign_in_for_controller_test(@admin)

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, 'This is a read-only oversight view.'
    assert_not_includes @response.body, 'Update Evaluation'
    assert_not_includes @response.body, 'Reschedule Evaluation'
  end

  test 'admin cannot schedule an evaluation' do
    sign_in_for_controller_test(@admin)

    post schedule_evaluators_evaluation_path(@requested_evaluation),
         params: { evaluation_date: 2.days.from_now, location: 'Admin attempt', notes: 'Admin attempt' }

    assert_redirected_to evaluators_evaluation_path(@requested_evaluation)
    assert_equal 'Only the assigned evaluator can update this evaluation.', flash[:alert]
    assert_equal 'requested', @requested_evaluation.reload.status
  end

  test 'admin cannot submit an evaluation report' do
    sign_in_for_controller_test(@admin)

    post submit_report_evaluators_evaluation_path(@evaluation), params: {
      evaluation: {
        needs: 'Admin attempt',
        notes: 'Admin attempt',
        location: 'Admin attempt',
        evaluation_date: Time.current,
        recommended_product_ids: [@product.id],
        products_tried: [{ product_id: @product.id, reaction: 'Positive' }],
        attendees: [{ name: 'Test User', relationship: 'Self' }]
      }
    }

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'Only the assigned evaluator can update this evaluation.', flash[:alert]
    assert_equal 'scheduled', @evaluation.reload.status
  end

  test 'other evaluator cannot mutate an evaluation' do
    sign_in_for_controller_test(@other_evaluator)

    post schedule_evaluators_evaluation_path(@requested_evaluation),
         params: { evaluation_date: 2.days.from_now, location: 'Other evaluator attempt' }

    assert_redirected_to evaluators_evaluations_path
    assert_equal 'Evaluation not found.', flash[:alert]
    assert_equal 'requested', @requested_evaluation.reload.status
  end
end
