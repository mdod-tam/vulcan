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

  test 'English staff help explains the confirmation audience' do
    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_select '#recommendation-notes-help', text: /shared verbatim.*applicant or managing guardian/
    assert_select '#working-notes-help', text: /internal notes.*not included.*confirmation emails or letters/
    assert_select '#complete_evaluation_recommendation_notes[aria-describedby~="recommendation-notes-help"]'
    assert_select '#working_evaluation_working_notes[aria-describedby~="working-notes-help"]'
  end

  test 'a new report shows catalog selections noncatalog details and an explicit no-suitable checkbox' do
    archived = create(:product, name: 'Archived trial device', archived_at: Time.current)
    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_select '#complete-evaluation-form input[type="radio"]', count: 0
    assert_select '#catalog-recommendations-group:not([hidden]):not([disabled])'
    assert_select '#complete_evaluation_no_suitable_product[type="checkbox"]:not([checked])'
    assert_select '#recommendation-notes-help strong', text: /shared verbatim.*Use Working Notes for internal notes/
    assert_select '#complete-internal-notes-help strong', text: 'Internal notes only.'
    assert_select '#complete-evaluation-form input[type="submit"][data-turbo-submits-with="Submitting report..."]'
    assert_select '#catalog-recommendations-group input[type="checkbox"][value=?]', @product.id.to_s
    assert_select '#catalog-recommendations-group input[type="checkbox"][value=?]', archived.id.to_s, count: 0
    assert_select "#trial-#{archived.id}"
    assert_select "#trial-#{archived.id}-reaction"
  end

  test 'no recommendations are rejected while the report remains editable' do
    submitted = {
      appointment_completed_at: 1.hour.ago.strftime('%Y-%m-%dT%H:%M'),
      notes: 'Preserved report notes', location: 'Library', attendees_field: 'Interpreter',
      products_tried_inputs: { @product.id.to_s => { selected: '1', reaction: 'Neutral' } },
      recommended_product_ids: [], recommendation_notes: '', no_suitable_product: '0'
    }

    assert_no_difference('Event.where(action: "evaluation_completed").count') do
      post submit_report_evaluators_evaluation_path(@evaluation), params: { evaluation: submitted }
    end

    assert_response :unprocessable_content
    assert_select '#submit-report-errors a[href="#catalog-recommendations-group"]'
    assert_select '#complete_evaluation_no_suitable_product:not([checked])'
    assert_select '#complete_evaluation_notes', text: submitted[:notes]
    assert_select '#complete_evaluation_location[value="Library"]'
    assert_select "#trial-#{@product.id}[checked]"
    assert_select "#trial-#{@product.id}-reaction option[value=Neutral][selected]"
    assert_equal 'scheduled', @evaluation.reload.status
    assert_nil @evaluation.report_submitted_at

    submitted[:recommended_product_ids] = [@product.id.to_s]
    submitted[:recommendation_notes] = 'Also recommend an external communication accessory.'
    post submit_report_evaluators_evaluation_path(@evaluation), params: { evaluation: submitted }

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal [@product.id], @evaluation.reload.recommended_product_ids
    assert_equal 'Neutral', @evaluation.products_tried.sole['reaction']
    assert_equal submitted[:recommendation_notes], @evaluation.recommendation_notes
  end

  test 'malformed trial rows are rejected before rendering the report form' do
    assert_no_difference('Event.where(action: "evaluation_completed").count') do
      post submit_report_evaluators_evaluation_path(@evaluation), params: {
        evaluation: { products_tried_inputs: [{ selected: '1', reaction: 'Satisfied' }] }
      }
    end
    assert_response :bad_request
    assert_equal 'scheduled', @evaluation.reload.status
  end

  test 'archived recommendations are rejected but archived trials survive replacement with an active recommendation' do
    @product.archive!
    replacement = create(:product, name: 'Available replacement device')
    submitted = {
      appointment_completed_at: 1.hour.ago.strftime('%Y-%m-%dT%H:%M'), location: 'Trial library',
      notes: 'Archived device trial observations', recommendation_notes: 'Keep the client-facing recommendation context.',
      recommended_product_ids: [@product.id.to_s],
      products_tried_inputs: { @product.id.to_s => { selected: '1', reaction: 'Neutral' } }
    }

    2.times do
      assert_no_difference(['Event.where(action: "evaluation_completed").count', 'EquipmentNeed.count']) do
        post submit_report_evaluators_evaluation_path(@evaluation), params: { evaluation: submitted }
      end

      assert_response :unprocessable_content
      assert_select '#submit-report-errors a[href="#catalog-recommendations-group"]'
      assert_select '#submit-report-recommended-product-ids-error', text: /cannot include archived catalog products/
      assert_select '#catalog-recommendations-group input[type="checkbox"][value=?]', @product.id.to_s, count: 0
      assert_select '#catalog-recommendations-group input[type="checkbox"][value=?]', replacement.id.to_s
      assert_select "#trial-#{@product.id}[checked]"
      assert_select "#trial-#{@product.id}-reaction option[value=Neutral][selected]"
      assert_select '#complete_evaluation_notes', text: submitted[:notes]
      assert_select '#complete_evaluation_recommendation_notes', text: submitted[:recommendation_notes]
      assert_equal 'scheduled', @evaluation.reload.status
      assert_nil @evaluation.report_submitted_at
    end

    submitted[:recommended_product_ids] = [replacement.id.to_s]
    assert_difference('Event.where(action: "evaluation_completed").count', 1) do
      post submit_report_evaluators_evaluation_path(@evaluation), params: { evaluation: submitted }
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'completed', @evaluation.reload.status
    assert_equal [replacement.id], @evaluation.recommended_product_ids
    assert_equal [{ 'product_id' => @product.id.to_s, 'reaction' => 'Neutral' }], @evaluation.products_tried
    assert_equal submitted[:notes], @evaluation.notes
    assert_equal submitted[:recommendation_notes], @evaluation.recommendation_notes
  end

  test 'completed reports retain archived recommendations when supplemental notes are saved' do
    evaluation = create(:evaluation, :completed, evaluator: @evaluator)
    products = evaluation.recommended_products.to_a
    products.each(&:archive!)
    original = evaluation.attributes.except('post_completion_notes', 'updated_at')

    get evaluators_evaluation_path(evaluation)
    assert_response :success
    products.each { |product| assert_includes response.body, product.name }

    patch evaluators_evaluation_path(evaluation), params: { evaluation: { post_completion_notes: 'Additional follow-up context.' } }

    assert_redirected_to evaluators_evaluation_path(evaluation)
    assert_equal 'Additional follow-up context.', evaluation.reload.post_completion_notes
    assert_equal original, evaluation.attributes.except('post_completion_notes', 'updated_at')
    assert_equal products.map(&:id).sort, evaluation.recommended_product_ids.sort
  end

  test 'administrator completed route applies the selected assignment scope' do
    assigned = create(:evaluation, :completed, evaluator: @admin)
    other = create(:evaluation, :completed, evaluator: @evaluator)
    sign_in_for_controller_test(@admin)

    get completed_evaluators_evaluations_path, params: { scope: 'mine' }

    assert_evaluation_rows(included: [assigned], excluded: [other, @evaluation, @requested_evaluation])
    assert_select '#evaluations-list-heading', text: /Completed Evaluations.*Assigned to Me/m

    get completed_evaluators_evaluations_path

    assert_evaluation_rows(included: [assigned, other], excluded: [@evaluation, @requested_evaluation])
    assert_select '#evaluations-list-heading', text: /All Evaluators/
    assert_select 'a[aria-current="page"]', text: 'Completed'
  end

  test 'administrator can switch between assigned and all evaluations' do
    assigned = create(:evaluation, evaluator: @admin, status: :scheduled)
    sign_in_for_controller_test(@admin)

    get evaluators_evaluations_path, params: { scope: 'mine' }

    assert_evaluation_rows(included: [assigned], excluded: [@evaluation, @requested_evaluation])
    assert_select '#evaluations-list-heading', text: /Assigned to Me/
    assert_select "a[href='#{evaluators_evaluations_path(scope: 'mine')}'].bg-white", text: 'My Evaluations'

    get evaluators_evaluations_path, params: { scope: 'all' }

    assert_evaluation_rows(included: [assigned, @evaluation, @requested_evaluation])
    assert_select '#evaluations-list-heading', text: /All Evaluators/
    assert_select "a[href='#{evaluators_evaluations_path(scope: 'all')}'].bg-white", text: 'All Evaluators'
  end

  test 'evaluator cannot expand scope beyond their assignments' do
    other = create(:evaluation, evaluator: @other_evaluator, status: :scheduled)

    get evaluators_evaluations_path, params: { scope: 'all', status: 'scheduled' }

    assert_evaluation_rows(included: [@evaluation], excluded: [other, @requested_evaluation])
    assert_select "a[aria-current='page'][href='#{evaluators_evaluations_path(scope: 'mine', status: 'scheduled')}']",
                  text: 'Scheduled'
  end

  test 'scheduled filters include confirmed evaluations in date order' do
    @evaluation.update!(evaluation_date: 3.days.from_now)
    confirmed = create(:evaluation, evaluator: @evaluator, status: :confirmed, evaluation_date: 2.days.from_now)

    [evaluators_evaluations_path(scope: 'mine', status: 'scheduled'), scheduled_evaluators_evaluations_path,
     pending_evaluators_evaluations_path].each do |path|
      get path

      assert_evaluation_rows(included: [confirmed, @evaluation], excluded: [@requested_evaluation])
      assert_body_order(%(href="#{evaluators_evaluation_path(confirmed)}"), %(href="#{evaluators_evaluation_path(@evaluation)}"))
      assert_select '#evaluations-list-heading', text: 'Scheduled Evaluations'
      assert_select 'a[aria-current="page"]', text: 'Scheduled'
    end
  end

  test 'follow-up filters combine cancelled and no-show within the selected scope' do
    cancelled = create(:evaluation, evaluator: @admin, status: :cancelled)
    no_show = create(:evaluation, evaluator: @admin, status: :no_show)
    other = create(:evaluation, evaluator: @evaluator, status: :cancelled)
    sign_in_for_controller_test(@admin)

    get evaluators_evaluations_path, params: { scope: 'mine', status: 'needs_followup' }

    assert_evaluation_rows(included: [cancelled, no_show], excluded: [other, @evaluation, @requested_evaluation])
    assert_select '#evaluations-list-heading', text: /Evaluations Needing Follow-up.*Assigned to Me/m
    assert_select 'a[aria-current="page"]', text: 'Needs Follow-up'

    get needs_followup_evaluators_evaluations_path

    assert_evaluation_rows(included: [cancelled, no_show, other], excluded: [@evaluation, @requested_evaluation])
    assert_select '#evaluations-list-heading', text: /All Evaluators/
    assert_select 'a[aria-current="page"]', text: 'Needs Follow-up'
  end

  test 'ordinary status filters remain distinct from aggregate filters' do
    cancelled = create(:evaluation, evaluator: @evaluator, status: :cancelled)
    no_show = create(:evaluation, evaluator: @evaluator, status: :no_show)

    get filtered_evaluators_evaluations_path(scope: 'mine', status: 'cancelled')

    assert_evaluation_rows(included: [cancelled], excluded: [no_show, @evaluation, @requested_evaluation])

    get requested_evaluators_evaluations_path

    assert_evaluation_rows(included: [@requested_evaluation], excluded: [cancelled, no_show, @evaluation])
    assert_select '#evaluations-list-heading', text: 'Needs Scheduling'
    assert_select 'a[aria-current="page"]', text: 'Needs Scheduling'
  end

  test 'unsupported filters fall back to authorized scope and show the applied selection' do
    other = create(:evaluation, evaluator: @other_evaluator, status: :scheduled)

    get evaluators_evaluations_path, params: { scope: 'unsupported', status: 'unsupported' }

    assert_evaluation_rows(included: [@evaluation, @requested_evaluation], excluded: [other])
    assert_select 'a[aria-current="page"]', text: 'All'
    assert_select "a[href='#{evaluators_evaluations_path(scope: 'mine')}']", text: 'All'

    sign_in_for_controller_test(@admin)
    get evaluators_evaluations_path, params: { scope: 'unsupported', status: 'unsupported' }

    assert_evaluation_rows(included: [@evaluation, @requested_evaluation, other])
    assert_select '#evaluations-list-heading', text: /All Evaluators/
    assert_select "a[aria-current='page'][href='#{evaluators_evaluations_path(scope: 'all')}']", text: 'All'
  end

  test 'submits report' do
    assert_difference('Event.where(action: "evaluation_completed").count', 1) do
      assert_changes '@evaluation.reload.status', from: 'scheduled', to: 'completed' do
        post submit_report_evaluators_evaluation_path(@evaluation), params: {
          evaluation: {
            notes: 'Final evaluation notes',
            location: 'Final location',
            appointment_completed_at: 1.hour.ago,
            recommended_product_ids: [@product.id],
            products_tried_inputs: { @product.id.to_s => { selected: '1', reaction: 'Satisfied' } },
            attendees_field: 'Test User'
          }
        }
      end
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
  end

  test 'show renders evaluation activity and application assignment labels' do
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
      action: 'evaluator_assigned',
      auditable: @evaluation.application,
      metadata: { application_id: @evaluation.application_id, evaluator_id: @evaluator.id, evaluator_name: @evaluator.full_name }
    )

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, 'Activity History'
    assert_includes @response.body, 'Evaluation Scheduled'
    assert_includes @response.body, 'Evaluation Cancelled'
    assert_includes @response.body, 'Constituent requested cancellation'
    assert_includes @response.body, 'Evaluation No-Show'
    assert_includes @response.body, 'Constituent missed evaluation'
    assert_includes @response.body, 'Evaluator Assigned'
    assert_includes @response.body, "Evaluator #{@evaluator.full_name} assigned"
    assert_select 'section[aria-labelledby="activity-history-heading"] span', text: 'Application'
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
    assert_select "a[href='#{application_details_evaluators_evaluation_path(@evaluation)}']", text: I18n.t('evaluator_context.link')
    assert_includes @response.body, 'Assigned Evaluator'
    assert_includes @response.body, 'Working Notes'
    assert_includes @response.body, 'Call constituent before arrival'
    assert_body_order(
      'Scheduled For',
      'Location',
      'Assigned Evaluator',
      'Working Notes',
      'Communication Preferences'
    )
    assert_includes @response.body, 'Constituent'
    assert_includes @response.body, 'Mark Evaluation as Completed'
    assert_includes @response.body, 'Cancel Evaluation'
    assert_includes @response.body, 'Reschedule Evaluation'
    assert_not_includes @response.body, 'Mark as No-Show'
    completion_form = form_html_for('complete-evaluation-form')

    assert_includes completion_form, 'Working Notes'
    assert_includes completion_form, %(action="#{submit_report_evaluators_evaluation_path(@evaluation)}")
    assert_includes completion_form, 'method="post"'
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
    assert_includes @response.body, 'Cancel Evaluation'
    cancel_form = form_html_for('cancel-evaluation-form')

    assert_includes cancel_form, %(action="#{cancel_evaluators_evaluation_path(@evaluation)}")
    assert_includes cancel_form, 'method="post"'
    assert_includes cancel_form, 'textarea'
    assert_not_includes cancel_form, 'Call constituent before arrival'
  end

  test 'no-show form does not prefill existing scheduling notes' do
    @evaluation.update!(evaluation_date: 1.day.ago, notes: 'Call constituent before arrival')

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    no_show_form = form_html_for('no-show-evaluation-form')

    assert_includes no_show_form, %(action="#{no_show_evaluators_evaluation_path(@evaluation)}")
    assert_includes no_show_form, 'method="post"'
    assert_includes no_show_form, 'textarea'
    assert_not_includes no_show_form, 'Call constituent before arrival'
  end

  test 'show renders schedule and cancel controls for requested evaluation' do
    get evaluators_evaluation_path(@requested_evaluation)

    assert_response :success
    assert_includes @response.body, 'Next Step'
    assert_includes @response.body, 'This evaluation has not been scheduled yet.'
    assert_includes @response.body, 'Schedule Evaluation'
    assert_includes @response.body, 'Cancel Evaluation'
    assert_no_training_session_context
  end

  test 'show renders outcome-first controls after scheduled time' do
    @evaluation.update!(evaluation_date: 1.day.ago)

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, 'This evaluation needs an outcome.'
    assert_includes @response.body, 'Record the evaluation outcome'
    assert_body_order(
      'This evaluation needs an outcome.',
      'Mark Evaluation as Completed',
      'Mark as No-Show',
      'Reschedule Evaluation',
      'Cancel Evaluation'
    )
    assert_no_training_session_context
  end

  test 'show renders reschedule controls for legacy rescheduled status' do
    @evaluation.update!(status: :rescheduled, reschedule_reason: 'Original date no longer works')

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, 'Current Rescheduling Reason'
    assert_includes @response.body, 'Original date no longer works'
    assert_includes @response.body, 'Reschedule Evaluation'
    assert_not_includes @response.body, 'No lifecycle actions are available for this evaluation status.'
  end

  test 'show renders reason and reschedule control for cancelled and no-show evaluations' do
    {
      cancelled: 'Current Cancellation Reason',
      no_show: 'Current No-Show Notes'
    }.each do |status, label|
      @evaluation.update!(status: status, notes: "Recorded #{status} details")

      get evaluators_evaluation_path(@evaluation)

      assert_response :success
      assert_includes @response.body, label
      assert_includes @response.body, "Recorded #{status} details"
      assert_includes @response.body, 'Reschedule Evaluation'
    end
  end

  test 'show renders completed details and only supplemental notes action for completed evaluation' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current, notes: 'Completed evaluation notes',
                        appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_includes @response.body, 'Appointment Completed At'
    assert_includes @response.body, 'Report Submitted At'
    assert_includes @response.body, 'Working Notes'
    assert_select '#working-notes-form', count: 0
    assert_includes @response.body, 'Attendees'
    assert_includes @response.body, 'Products Tried'
    assert_includes @response.body, 'Recommended products from catalog'
    assert_includes @response.body, 'Working Notes'
    assert_not_includes @response.body, 'Mark Evaluation as Completed'
    assert_not_includes @response.body, 'Cancel Evaluation'
    assert_not_includes @response.body, 'Reschedule Evaluation'
    assert_no_training_session_context
  end

  test 'assigned evaluator can schedule an evaluation' do
    assert_difference('Event.where(action: "evaluation_scheduled").count', 1) do
      post schedule_evaluators_evaluation_path(@requested_evaluation),
           params: {
             evaluation: { evaluation_date: 2.days.from_now, location: 'Library', notes: 'Scheduled by evaluator' }
           }
    end

    assert_redirected_to evaluators_evaluation_path(@requested_evaluation)
    assert_equal 'scheduled', @requested_evaluation.reload.status
    assert_equal 'Library', @requested_evaluation.location
  end

  test 'assigned evaluator can cancel evaluation after scheduled time' do
    @evaluation.update!(evaluation_date: 1.day.ago)

    assert_difference('Event.where(action: "evaluation_cancelled").count', 1) do
      post cancel_evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          notes: 'Constituent no longer wants evaluator support'
        }
      }
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'Evaluation cancelled successfully.', flash[:notice]
    assert_equal 'cancelled', @evaluation.reload.status
    assert_equal 'Constituent no longer wants evaluator support', @evaluation.notes
  end

  test 'requested report exposes outside consultation only to its assigned administrator and preserves retry inputs' do
    @requested_evaluation.update!(evaluator: @admin)
    sign_in_for_controller_test(@admin)
    get evaluators_evaluation_path(@requested_evaluation)

    assert_response :success
    assert_select '#complete-evaluation-form', count: 1
    assert_select '#complete_evaluation_assessment_source[required] option[value="outside_specialist"]'
    assert_select '#complete_evaluation_assessment_source option[value="direct_assessment"]', count: 0
    assert_select '#complete_evaluation_location[required]', count: 0
    submitted = {
      assessment_source: 'outside_specialist', appointment_completed_at: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'),
      notes: 'Written recommendations from outside specialist consultation.', location: '', attendees_field: '',
      recommended_product_ids: [@product.id.to_s], products_tried_inputs: {}
    }

    assert_no_difference('Event.where(action: "evaluation_completed").count') do
      post submit_report_evaluators_evaluation_path(@requested_evaluation), params: { evaluation: submitted }
    end
    assert_response :unprocessable_content
    assert_select '#complete_evaluation_assessment_source option[value="outside_specialist"][selected]'
    assert_select '#complete_evaluation_appointment_completed_at[value=?]', submitted[:appointment_completed_at]
    assert_select '#complete_evaluation_notes', text: submitted[:notes]
    assert_select '#complete-evaluation-form input[name="evaluation[recommended_product_ids][]"][value=?][checked]', @product.id.to_s
    assert_select '#complete-evaluation-form input[data-trial-choice][checked]', count: 0
    assert_equal 'requested', @requested_evaluation.reload.status

    submitted[:appointment_completed_at] = 2.days.ago.strftime('%Y-%m-%dT%H:%M')
    post submit_report_evaluators_evaluation_path(@requested_evaluation), params: { evaluation: submitted }

    assert_redirected_to evaluators_evaluation_path(@requested_evaluation)
    assert_equal 'completed', @requested_evaluation.reload.status
    assert_equal 'outside_specialist', @requested_evaluation.assessment_source
    assert_nil @requested_evaluation.evaluation_date
    assert_empty @requested_evaluation.products_tried
  end

  test 'administrator oversight cannot expose or submit another evaluators outside consultation action' do
    sign_in_for_controller_test(@admin)
    get evaluators_evaluation_path(@requested_evaluation)

    assert_select '#complete-evaluation-form', count: 0
    assert_no_difference('Event.where(action: "evaluation_completed").count') do
      post submit_report_evaluators_evaluation_path(@requested_evaluation), params: {
        evaluation: { assessment_source: 'outside_specialist' }
      }
    end
    assert_redirected_to evaluators_evaluation_path(@requested_evaluation)
    assert_equal 'requested', @requested_evaluation.reload.status
  end

  test 'historical outside consultation remains readable and accepts supplemental notes after archival' do
    evaluation = create(
      :evaluation, :completed,
      evaluator: @admin, assessment_source: 'outside_specialist',
      evaluation_date: nil, location: nil, products_tried: []
    )
    evaluation.application.transition_status!(:archived, actor: @admin)
    sign_in_for_controller_test(@admin)

    get evaluators_evaluation_path(evaluation)
    assert_response :success
    assert_includes response.body, 'Outside-specialist consultation'
    original = evaluation.attributes.except('post_completion_notes', 'updated_at')
    patch evaluators_evaluation_path(evaluation), params: { evaluation: { post_completion_notes: 'Additional consultation context' } }

    assert_redirected_to evaluators_evaluation_path(evaluation)
    assert_equal 'Additional consultation context', evaluation.reload.post_completion_notes
    assert_equal original, evaluation.attributes.except('post_completion_notes', 'updated_at')
  end

  test 'assigned evaluator can complete evaluation before scheduled time' do
    @evaluation.update!(evaluation_date: 2.days.from_now)

    assert_difference('Event.where(action: "evaluation_completed").count', 1) do
      post submit_report_evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          appointment_completed_at: 1.hour.ago,
          notes: 'Final evaluation notes',
          location: 'Final location',
          recommended_product_ids: [@product.id],
          products_tried_inputs: { @product.id.to_s => { selected: '1', reaction: 'Satisfied' } },
          attendees_field: 'Test User'
        }
      }
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'Evaluation submitted successfully.', flash[:notice]
    assert_equal 'completed', @evaluation.reload.status
    assert_equal [@product.id], @evaluation.recommended_product_ids
  end

  test 'failed completion reloads scheduled state before rendering show controls' do
    @evaluation.update!(evaluation_date: 2.days.from_now)

    assert_no_difference('Event.where(action: "evaluation_completed").count') do
      post submit_report_evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          notes: '',
          appointment_completed_at: 1.hour.ago,
          location: 'Final location',
          recommended_product_ids: [@product.id],
          products_tried_inputs: { @product.id.to_s => { selected: '1', reaction: 'Satisfied' } },
          attendees_field: 'Test User'
        }
      }
    end

    assert_response :unprocessable_content
    assert_includes @response.body, 'Failed to submit evaluation:'
    assert_select '#submit-report-errors a[href="#complete_evaluation_notes"]', text: "Notes can't be blank", count: 1
    assert_select '#submit-report-notes-error', text: "Notes can't be blank"
    assert_includes @response.body, 'Mark Evaluation as Completed'
    assert_select '#supplemental-notes-form', count: 0
    assert_equal 'scheduled', @evaluation.reload.status
  end

  test 'failed report preserves every visible input and remains retryable after clearing selections' do
    original_date = @evaluation.evaluation_date
    submitted = {
      appointment_completed_at: 1.day.from_now.strftime('%Y-%m-%dT%H:%M'),
      location: 'Retry Library', notes: 'Detailed observations to preserve', attendees_field: 'Interpreter, Family friend',
      products_tried_inputs: { @product.id.to_s => { selected: '1', reaction: 'Satisfied' } }, recommended_product_ids: [''],
      recommendation_notes: 'Family-facing recommendation context',
      application_id: create(:application).id, evaluator_id: @other_evaluator.id, status: 'cancelled'
    }

    2.times do
      post submit_report_evaluators_evaluation_path(@evaluation), params: { evaluation: submitted }

      assert_response :unprocessable_content
      assert_select '#complete_evaluation_appointment_completed_at[value=?]', submitted[:appointment_completed_at]
      assert_select '#complete_evaluation_location[value=?]', submitted[:location]
      assert_select '#complete_evaluation_attendees_field[value=?]', submitted[:attendees_field]
      assert_select '#complete_evaluation_notes', text: submitted[:notes]
      assert_select '#complete_evaluation_recommendation_notes', text: submitted[:recommendation_notes]
      assert_select '#complete_evaluation_no_suitable_product:not([checked])'
      assert_select "#complete-evaluation-form input#trial-#{@product.id}[checked]"
      assert_select "#complete-evaluation-form input[name='evaluation[recommended_product_ids][]'][checked]", count: 0
      assert_equal 'scheduled', @evaluation.reload.status
      assert_equal original_date, @evaluation.evaluation_date
      assert_not_equal submitted[:notes], @evaluation.notes
      assert_not_equal submitted[:application_id], @evaluation.application_id
      assert_equal @evaluator.id, @evaluation.evaluator_id
      assert_nil flash[:alert]
      assert_select '[role="alert"]', count: 1
    end

    submitted[:appointment_completed_at] = 1.hour.ago.strftime('%Y-%m-%dT%H:%M')
    submitted[:attendees_field] = ''
    submitted[:location] = 'Corrected Location'
    submitted[:recommended_product_ids] = [@product.id.to_s]
    post submit_report_evaluators_evaluation_path(@evaluation), params: { evaluation: submitted }

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'completed', @evaluation.reload.status
    assert_equal [], @evaluation.attendees
    assert_equal 'Corrected Location', @evaluation.location
    assert_equal submitted[:notes], @evaluation.notes
    assert_equal submitted[:recommendation_notes], @evaluation.recommendation_notes
    assert_equal 'catalog_products', @evaluation.recommendation_outcome
    assert_not_equal submitted[:application_id], @evaluation.application_id
    assert_equal @evaluator.id, @evaluation.evaluator_id
    assert_equal original_date, @evaluation.evaluation_date
  end

  test 'failed scheduling preserves typed values and a corrected retry schedules the persisted record' do
    submitted = { evaluation_date: 1.hour.ago.strftime('%Y-%m-%dT%H:%M'), location: '', notes: 'Call before arrival' }

    post schedule_evaluators_evaluation_path(@requested_evaluation), params: { evaluation: submitted }

    assert_response :unprocessable_content
    assert_select '#schedule_evaluation_evaluation_date[value=?]', submitted[:evaluation_date]
    assert_select '#schedule_evaluation_location[value=""]'
    assert_select '#schedule_evaluation_notes', text: submitted[:notes]
    assert_equal 'requested', @requested_evaluation.reload.status

    submitted[:evaluation_date] = 2.days.from_now.strftime('%Y-%m-%dT%H:%M')
    submitted[:location] = 'Library'
    post schedule_evaluators_evaluation_path(@requested_evaluation), params: { evaluation: submitted }

    assert_redirected_to evaluators_evaluation_path(@requested_evaluation)
    assert_equal 'scheduled', @requested_evaluation.reload.status
    assert_equal 'Library', @requested_evaluation.location
  end

  test 'failed rescheduling preserves blank location and attempted date without changing the appointment' do
    original_date = @evaluation.evaluation_date
    submitted = { evaluation_date: 2.days.from_now.strftime('%Y-%m-%dT%H:%M'), location: '', reschedule_reason: '' }

    post reschedule_evaluators_evaluation_path(@evaluation), params: { evaluation: submitted }

    assert_response :unprocessable_content
    assert_select '#reschedule_evaluation_evaluation_date[value=?]', submitted[:evaluation_date]
    assert_select '#reschedule_evaluation_location[value=""]'
    assert_select '#reschedule_evaluation_reschedule_reason', text: ''
    assert_equal original_date, @evaluation.reload.evaluation_date

    submitted[:reschedule_reason] = 'Contact person requested another time'
    post reschedule_evaluators_evaluation_path(@evaluation), params: { evaluation: submitted }

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal '', @evaluation.reload.location
    assert_equal submitted[:reschedule_reason], @evaluation.reschedule_reason
  end

  test 'action forms have distinct field IDs and matching labels' do
    @evaluation.update!(evaluation_date: 1.hour.ago)

    get evaluators_evaluation_path(@evaluation)

    assert_select '[id]' do |elements|
      ids = elements.pluck('id')
      assert_equal ids.uniq, ids
    end
    %w[complete_evaluation_notes cancel_evaluation_notes no-show_evaluation_notes reschedule_evaluation_location].each do |id|
      assert_select "label[for='#{id}']", count: 1
      assert_select "[id='#{id}']", count: 1
    end
  end

  test 'cancellation rejection preserves the entered reason for correction' do
    post cancel_evaluators_evaluation_path(@evaluation), params: { evaluation: { notes: ' ' } }

    assert_response :unprocessable_content
    assert_select '#cancel_evaluation_notes', text: ' '
    assert_equal 'scheduled', @evaluation.reload.status

    post cancel_evaluators_evaluation_path(@evaluation), params: { evaluation: { notes: 'Contact person declined' } }

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'Contact person declined', @evaluation.reload.notes
  end

  test 'failed no-show audit rolls back the outcome and preserves the note for retry' do
    @evaluation.update!(evaluation_date: 1.hour.ago)
    failed_event = Event.new
    failed_event.errors.add(:base, 'Audit record unavailable')

    AuditEventService.stub(:log, ->(**) { raise ActiveRecord::RecordInvalid, failed_event }) do
      post no_show_evaluators_evaluation_path(@evaluation), params: { evaluation: { notes: 'Reached voicemail' } }
    end

    assert_response :unprocessable_content
    assert_select '#no-show_evaluation_notes', text: 'Reached voicemail'
    assert_equal 'scheduled', @evaluation.reload.status

    post no_show_evaluators_evaluation_path(@evaluation), params: { evaluation: { notes: '' } }

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'no_show', @evaluation.reload.status
    assert_nil @evaluation.notes
  end

  test 'legacy completed evaluation dates remain explicitly unrecorded' do
    @evaluation.update!(status: :completed, appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)
    @evaluation.update_columns(appointment_completed_at: nil, report_submitted_at: nil)

    get evaluators_evaluation_path(@evaluation)

    assert_response :success
    assert_select 'dt', text: 'Scheduled For'
    assert_select 'dt', text: 'Appointment Completed At'
    assert_select 'dt', text: 'Report Submitted At'
    assert_select 'dd', text: 'Not recorded', count: 2
    assert_select "textarea[name='evaluation[post_completion_notes]']", count: 1
  end

  test 'assigned evaluator can mark evaluation as no-show after scheduled time' do
    @evaluation.update!(evaluation_date: 1.day.ago)

    assert_difference('Event.where(action: "evaluation_no_show").count', 1) do
      post no_show_evaluators_evaluation_path(@evaluation), params: {
        evaluation: {
          notes: 'Constituent did not attend'
        }
      }
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'Evaluation marked as no-show.', flash[:notice]
    assert_equal 'no_show', @evaluation.reload.status
    assert_equal 'Constituent did not attend', @evaluation.notes
  end

  test 'supplemental notes update cannot mark evaluation as scheduled or bypass schedule service' do
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
    assert_includes @response.body, 'This evaluation action must use the appropriate lifecycle control.'
    assert_equal 'cancelled', @evaluation.reload.status
  end

  test 'supplemental notes update cannot reschedule completed evaluation' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current,
                        appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)
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
    assert_includes @response.body, 'This evaluation action must use the appropriate lifecycle control.'
    assert_equal 'completed', @evaluation.reload.status
    assert_in_delta original_evaluation_date, @evaluation.evaluation_date, 1.second
  end

  test 'reschedule action rejects completed evaluation' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current,
                        appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)
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
    assert_includes @response.body, 'Only scheduled, confirmed, cancelled, or no-show evaluations can be rescheduled.'
    assert_equal 'completed', @evaluation.reload.status
    assert_in_delta original_evaluation_date, @evaluation.evaluation_date, 1.second
  end

  test 'update allows supplemental post-completion notes' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current,
                        appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)

    patch evaluators_evaluation_path(@evaluation), params: {
      evaluation: {
        post_completion_notes: 'Follow-up note after submission'
      }
    }

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'Evaluation updated successfully.', flash[:notice]
    assert_equal 'Follow-up note after submission', @evaluation.reload.post_completion_notes
  end

  test 'supplemental notes preserve submission time and completed report order' do
    freeze_time do
      older = create(
        :evaluation, :completed, evaluator: @evaluator,
                                 appointment_completed_at: 3.days.ago, report_submitted_at: 2.days.ago
      )
      newer = create(
        :evaluation, :completed, evaluator: @evaluator,
                                 appointment_completed_at: 2.days.ago, report_submitted_at: 1.day.ago
      )
      submitted_at = older.report_submitted_at
      updated_at = older.updated_at
      travel 1.minute

      patch evaluators_evaluation_path(older), params: {
        evaluation: { post_completion_notes: 'Additional observation on the older report' }
      }

      assert_redirected_to evaluators_evaluation_path(older)
      assert_equal 'Additional observation on the older report', older.reload.post_completion_notes
      assert_equal submitted_at, older.report_submitted_at
      assert_operator older.updated_at, :>, updated_at
      assert_operator older.updated_at, :>, newer.updated_at

      get completed_evaluators_evaluations_path

      assert_evaluation_rows(included: [newer, older], excluded: [@evaluation, @requested_evaluation])
      assert_body_order(%(href="#{evaluators_evaluation_path(newer)}"), %(href="#{evaluators_evaluation_path(older)}"))

      get evaluators_dashboard_path

      assert_response :success
      assert_select '#recent-completed-heading'
      assert_body_order(%(href="#{evaluators_evaluation_path(newer)}"), %(href="#{evaluators_evaluation_path(older)}"))
    end
  end

  test 'cancel action rejects completed evaluation' do
    @evaluation.update!(status: :completed, evaluation_date: Time.current,
                        appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current)

    post cancel_evaluators_evaluation_path(@evaluation), params: {
      evaluation: {
        notes: 'Attempt to undo history'
      }
    }

    assert_response :unprocessable_content
    assert_includes @response.body, 'Only requested, scheduled, or confirmed evaluations can be cancelled.'
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
         params: {
           evaluation: { evaluation_date: 2.days.from_now, location: 'Admin attempt', notes: 'Admin attempt' }
         }

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
         params: { evaluation: { evaluation_date: 2.days.from_now, location: 'Other evaluator attempt' } }

    assert_redirected_to evaluators_evaluations_path
    assert_equal 'Evaluation not found.', flash[:alert]
    assert_equal 'requested', @requested_evaluation.reload.status
  end

  private

  def assert_evaluation_rows(included:, excluded: [])
    assert_response :success
    included.each { |evaluation| assert_select "tbody a[href='#{evaluators_evaluation_path(evaluation)}']", count: 1 }
    excluded.each { |evaluation| assert_select "tbody a[href='#{evaluators_evaluation_path(evaluation)}']", count: 0 }
  end

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

    start_index = @response.body.rindex('<form', start_index)
    assert start_index, "Expected #{form_id.inspect} to be on a form tag"

    end_index = @response.body.index('</form>', start_index)
    assert end_index, "Expected form #{form_id.inspect} to have a closing tag"

    @response.body[start_index..end_index]
  end
end
