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
      user: @evaluator,
      action: 'evaluation_cancelled',
      auditable: @evaluation,
      metadata: { evaluation_id: @evaluation.id, cancellation_reason: 'Constituent requested cancellation' }
    )
    Event.create!(
      user: @evaluator,
      action: 'evaluation_no_show',
      auditable: @evaluation,
      metadata: { evaluation_id: @evaluation.id, no_show_notes: 'Constituent missed evaluation' }
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
    assert_includes @response.body, 'Evaluation Cancelled'
    assert_includes @response.body, 'Constituent requested cancellation'
    assert_includes @response.body, 'Evaluation No-Show'
    assert_includes @response.body, 'Constituent missed evaluation'
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

  test 'show renders completion controls before scheduled time' do
    @evaluation.update!(
      evaluation_date: 2.days.from_now,
      location: 'Library',
      notes: 'Call constituent before arrival'
    )

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.view_full_application_details')
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.assigned_evaluator')
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.current_evaluator_notes')
    assert_includes @response.body, 'Call constituent before arrival'
    assert_body_order(
      I18n.t('evaluators.evaluations.show.scheduled_for'),
      I18n.t('evaluators.evaluations.show.location'),
      I18n.t('evaluators.evaluations.show.assigned_evaluator'),
      I18n.t('evaluators.evaluations.show.current_evaluator_notes'),
      I18n.t('evaluators.evaluations.show.communication_preferences')
    )
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.constituent')
    assert_includes @response.body, I18n.t('evaluators.evaluations.completion_form.title')
    assert_includes @response.body, I18n.t('evaluators.evaluations.cancel_form.title')
    assert_includes @response.body, I18n.t('evaluators.evaluations.reschedule_form.title')
    assert_not_includes @response.body, I18n.t('evaluators.evaluations.no_show_form.title')
    completion_form = form_html_for('complete-evaluation-form')

    assert_includes completion_form, I18n.t('evaluators.evaluations.completion_form.notes_label')
    assert_not_includes completion_form, 'Call constituent before arrival'
    assert_no_training_session_context
  end

  test 'show includes skip link and main content target' do
    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, 'href="#main-content"'
    assert_includes @response.body, 'id="main-content"'
  end

  test 'cancel form does not prefill existing scheduling notes' do
    @evaluation.update!(evaluation_date: 2.days.from_now, notes: 'Call constituent before arrival')

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, I18n.t('evaluators.evaluations.cancel_form.title')
    cancel_form = form_html_for('cancel-evaluation-form')

    assert_includes cancel_form, 'textarea'
    assert_not_includes cancel_form, 'Call constituent before arrival'
  end

  test 'no-show form does not prefill existing scheduling notes' do
    @evaluation.update!(evaluation_date: 1.day.ago, notes: 'Call constituent before arrival')

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    no_show_form = form_html_for('no-show-evaluation-form')

    assert_includes no_show_form, 'textarea'
    assert_not_includes no_show_form, 'Call constituent before arrival'
  end

  test 'show renders schedule and cancel controls for requested evaluation' do
    get evaluators_evaluation_path(@requested_evaluation)

    assert_response :success
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.next_step')
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.requested_next_step_title')
    assert_includes @response.body, I18n.t('evaluators.evaluations.schedule_form.submit')
    assert_includes @response.body, I18n.t('evaluators.evaluations.cancel_form.submit')
    assert_no_training_session_context
  end

  test 'show renders outcome-first controls after scheduled time' do
    @evaluation.update!(evaluation_date: 1.day.ago)

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.outcome_due_title')
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.outcome_due_body')
    assert_body_order(
      I18n.t('evaluators.evaluations.show.outcome_due_title'),
      I18n.t('evaluators.evaluations.completion_form.title'),
      I18n.t('evaluators.evaluations.no_show_form.title'),
      I18n.t('evaluators.evaluations.cancel_form.title'),
      I18n.t('evaluators.evaluations.reschedule_form.title')
    )
    assert_no_training_session_context
  end

  test 'show renders reschedule controls for legacy rescheduled status' do
    @evaluation.update!(status: :rescheduled, reschedule_reason: 'Original date no longer works')

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.current_rescheduling_reason')
    assert_includes @response.body, 'Original date no longer works'
    assert_includes @response.body, I18n.t('evaluators.evaluations.reschedule_form.title')
    assert_not_includes @response.body, I18n.t('evaluators.evaluations.show.lifecycle_unavailable')
  end

  test 'show renders reason and reschedule control for cancelled and no-show evaluations' do
    {
      cancelled: I18n.t('evaluators.evaluations.show.current_cancellation_reason'),
      no_show: I18n.t('evaluators.evaluations.show.current_no_show_notes')
    }.each do |status, label|
      @evaluation.update!(status: status, notes: "Recorded #{status} details")

      get evaluators_evaluation_path(@evaluation)

      assert_response :success
      assert_includes @response.body, label
      assert_includes @response.body, "Recorded #{status} details"
      assert_includes @response.body, I18n.t('evaluators.evaluations.reschedule_form.title')
    end
  end

  test 'show renders completed details and only supplemental notes action for completed evaluation' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current, notes: 'Completed evaluation notes')

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.completed_at')
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.evaluator_notes')
    assert_not_includes @response.body, I18n.t('evaluators.evaluations.show.current_evaluator_notes')
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.attendees')
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.products_tried')
    assert_includes @response.body, I18n.t('evaluators.evaluations.show.recommended_products')
    assert_includes @response.body, I18n.t('evaluators.evaluations.completed_notes_form.title')
    assert_not_includes @response.body, I18n.t('evaluators.evaluations.completion_form.title')
    assert_not_includes @response.body, I18n.t('evaluators.evaluations.cancel_form.title')
    assert_not_includes @response.body, I18n.t('evaluators.evaluations.reschedule_form.title')
    assert_no_training_session_context
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

  test 'assigned evaluator can cancel evaluation after scheduled time' do
    @evaluation.update!(evaluation_date: 1.day.ago)

    assert_difference('Event.where(action: "evaluation_cancelled").count', 1) do
      patch evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          status: 'cancelled',
          notes: 'Constituent no longer wants evaluator support'
        }
      }
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'Evaluation cancelled successfully.', flash[:notice]
    assert_equal 'cancelled', @evaluation.reload.status
    assert_equal 'Constituent no longer wants evaluator support', @evaluation.notes
  end

  test 'assigned evaluator can complete evaluation before scheduled time' do
    @evaluation.update!(evaluation_date: 2.days.from_now)

    assert_difference('Event.where(action: "evaluation_completed").count', 1) do
      patch evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          status: 'completed',
          needs: 'Final needs assessment',
          notes: 'Final evaluation notes',
          location: 'Final location',
          recommended_product_ids: [@product.id],
          products_tried_field: [@product.id],
          attendees_field: 'Test User'
        }
      }
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal I18n.t('evaluations.complete.success'), flash[:notice]
    assert_equal 'completed', @evaluation.reload.status
    assert_equal [@product.id], @evaluation.recommended_product_ids
  end

  test 'assigned evaluator can mark evaluation as no-show after scheduled time' do
    @evaluation.update!(evaluation_date: 1.day.ago)

    assert_difference('Event.where(action: "evaluation_no_show").count', 1) do
      patch evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          status: 'no_show',
          notes: 'Constituent did not attend'
        }
      }
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal I18n.t('evaluations.no_show.success'), flash[:notice]
    assert_equal 'no_show', @evaluation.reload.status
    assert_equal 'Constituent did not attend', @evaluation.notes
  end

  test 'generic update cannot mark evaluation as scheduled or bypass schedule service' do
    @evaluation.update!(status: :cancelled)

    assert_no_difference('Event.where(action: "evaluation_scheduled").count') do
      patch evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          status: 'scheduled',
          evaluation_date: 2.days.from_now,
          location: 'Library'
        }
      }
    end

    assert_response :unprocessable_content
    assert_includes @response.body, I18n.t('evaluators.evaluations.flash.lifecycle_update_restricted')
    assert_equal 'cancelled', @evaluation.reload.status
  end

  test 'generic update cannot reschedule completed evaluation' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current)
    original_evaluation_date = @evaluation.evaluation_date

    assert_no_difference('Event.where(action: "evaluation_rescheduled").count') do
      patch evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          status: 'completed',
          evaluation_date: 2.days.from_now,
          reschedule_reason: 'Attempt to bypass service'
        }
      }
    end

    assert_response :unprocessable_content
    assert_includes @response.body, I18n.t('evaluators.evaluations.flash.lifecycle_update_restricted')
    assert_equal 'completed', @evaluation.reload.status
    assert_in_delta original_evaluation_date, @evaluation.evaluation_date, 1.second
  end

  test 'reschedule action rejects completed evaluation' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current)
    original_evaluation_date = @evaluation.evaluation_date

    assert_no_difference('Event.where(action: "evaluation_rescheduled").count') do
      post reschedule_evaluators_evaluation_path(@evaluation),
           params: {
             evaluation: {
               evaluation_date: 2.days.from_now,
               location: 'Library',
               reschedule_reason: 'Attempt to bypass lifecycle guard'
             }
           }
    end

    assert_response :unprocessable_content
    assert_includes @response.body, I18n.t('evaluations.reschedule.wrong_status')
    assert_equal 'completed', @evaluation.reload.status
    assert_in_delta original_evaluation_date, @evaluation.evaluation_date, 1.second
  end

  test 'generic update still allows supplemental post-completion notes' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current)

    patch evaluators_evaluation_path(@evaluation), params: {
      evaluation: {
        status: 'completed',
        post_completion_notes: 'Follow-up note after submission'
      }
    }

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal I18n.t('evaluators.evaluations.flash.update_success'), flash[:notice]
    assert_equal 'Follow-up note after submission', @evaluation.reload.post_completion_notes
  end

  test 'assigned evaluator cannot cancel completed evaluation through update' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current)

    patch evaluators_evaluation_path(@evaluation), params: {
      evaluation: {
        status: 'cancelled',
        notes: 'Attempt to undo history'
      }
    }

    assert_response :unprocessable_content
    assert_includes @response.body, I18n.t('evaluations.cancel.wrong_status')
    assert_equal 'completed', @evaluation.reload.status
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

  test 'admin cannot patch lifecycle actions through update' do
    sign_in_for_controller_test(@admin)

    assert_no_difference('Event.where(action: "evaluation_cancelled").count') do
      patch evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          status: 'cancelled',
          notes: 'Admin attempt'
        }
      }
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'Only the assigned evaluator can update this evaluation.', flash[:alert]
    assert_equal 'scheduled', @evaluation.reload.status
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

  private

  def assert_body_order(*snippets)
    positions = snippets.map do |snippet|
      position = @response.body.index(snippet)
      assert position, "Expected response body to include #{snippet.inspect}"
      position
    end

    assert_equal positions.sort, positions, "Expected snippets to appear in order: #{snippets.inspect}"
  end

  def assert_no_training_session_context
    assert_not_includes @response.body, 'Training Progress'
    assert_not_includes @response.body, 'Session Capacity'
    assert_not_includes @response.body, 'Open Training Sessions'
  end

  def form_html_for(form_id)
    start_index = @response.body.index("id=\"#{form_id}\"")
    assert start_index, "Expected response body to include form #{form_id.inspect}"

    end_index = @response.body.index('</form>', start_index)
    assert end_index, "Expected form #{form_id.inspect} to have a closing tag"

    @response.body[start_index..end_index]
  end
end
