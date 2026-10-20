# frozen_string_literal: true

require 'test_helper'

class EvaluatorWorkingNotesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @evaluator = create(:evaluator)
    @evaluation = create(:evaluation, evaluator: @evaluator, status: :requested, evaluation_date: nil)
    sign_in_for_controller_test(@evaluator)
  end

  test 'assigned evaluator saves outreach notes without scheduling or submitting a report' do
    assert_difference('Event.where(action: "evaluation_working_notes_updated").count', 1) do
      post save_working_notes_evaluators_evaluation_path(@evaluation), params: {
        evaluation: { working_notes: 'Called managing guardian and left voicemail.', status: 'completed', notes: 'Forged report' }
      }
    end

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    @evaluation.reload
    assert_equal 'Called managing guardian and left voicemail.', @evaluation.working_notes
    assert_equal 'requested', @evaluation.status
    assert_nil @evaluation.evaluation_date
    assert_nil @evaluation.report_submitted_at
    assert_not_equal 'Forged report', @evaluation.notes

    get evaluators_evaluation_path(@evaluation)
    assert_select '#working-notes-form textarea', text: @evaluation.working_notes
  end

  test 'internal note fields use Working Notes labels and bold linked privacy hints' do
    get evaluators_evaluation_path(@evaluation)

    assert_select '#working-notes-heading', text: 'Working Notes'
    assert_select '#working-notes-form label', text: 'Working Notes'
    assert_select '#schedule-evaluation-form label[for="schedule_evaluation_notes"]', text: 'Working Notes'
    assert_select 'dt', text: 'Working Notes'
    %w[working-notes-help schedule-notes-help cancel-notes-help].each do |id|
      assert_select "##{id} strong", text: 'Internal notes only.'
      assert_select "textarea[aria-describedby~='#{id}']"
    end
    assert_select 'dd strong', text: 'Internal notes only.'
  end

  test 'reschedule precedes cancel after the available outcome actions' do
    expected = %w[complete-evaluation-form reschedule-evaluation-form cancel-evaluation-form]
    %i[scheduled confirmed].each do |status|
      @evaluation.update!(status: status, evaluation_date: 1.day.from_now)
      get evaluators_evaluation_path(@evaluation)

      form_ids = response.parsed_body.css('section[aria-label="Evaluation Actions"] form[id]').pluck('id')
      assert_equal expected, form_ids
    end
    @evaluation.update!(status: :scheduled, evaluation_date: 1.hour.ago)
    get evaluators_evaluation_path(@evaluation)

    form_ids = response.parsed_body.css('section[aria-label="Evaluation Actions"] form[id]').pluck('id')
    assert_equal expected.dup.insert(1, 'no-show-evaluation-form'), form_ids
    assert_select '#reschedule-reason-help strong', text: 'Internal notes only.'
    assert_select '#cancel-notes-help strong', text: 'Internal notes only.'
    assert_select '#no-show-notes-help strong', text: 'Internal notes only.'
    assert_select '#no-show-evaluation-form textarea[aria-describedby~="no-show-notes-help"]'
  end

  test 'completed report preserves recorded satisfaction when supplemental notes change' do
    @evaluation.update!(status: :completed, evaluation_date: 1.day.ago, appointment_completed_at: 1.hour.ago,
                        report_submitted_at: Time.current, working_notes: 'Prior coordination', post_completion_notes: 'Follow-up observation')
    original_trials = @evaluation.products_tried.deep_dup
    get evaluators_evaluation_path(@evaluation)

    form_ids = response.parsed_body.css('section[aria-label="Evaluation Actions"] form[id]').pluck('id')
    assert_equal ['supplemental-notes-form'], form_ids
    assert_select '#working-notes-form', count: 0
    assert_select 'dt', text: 'Working Notes'
    assert_select 'dd strong', text: 'Internal notes only.'
    assert_select '#working-notes-help strong', text: 'Internal notes only.'
    assert_select '#supplemental-notes-help strong', text: 'Internal notes only.'
    assert_select '#supplemental-notes-form label', text: 'Working Notes'
    assert_select '#supplemental-notes-form textarea[aria-describedby="supplemental-notes-help"]', text: 'Follow-up observation'
    assert_select 'dt', text: 'Recommended products from catalog'
    assert_select 'li', text: /Satisfied/
    assert_select 'li', text: /Neutral/

    patch evaluators_evaluation_path(@evaluation), params: {
      evaluation: { post_completion_notes: 'Later follow-up observation' }
    }

    assert_redirected_to evaluators_evaluation_path(@evaluation)
    assert_equal 'Later follow-up observation', @evaluation.reload.post_completion_notes
    assert_equal 'Prior coordination', @evaluation.working_notes
    assert_equal original_trials, @evaluation.products_tried
  end

  test 'working note failure preserves entered text and renders a focusable error summary' do
    invalid_event = Event.new
    invalid_event.errors.add(:base, 'Audit unavailable')
    @evaluation.update!(working_notes: 'Previously saved outreach note')
    original_notes = @evaluation.working_notes

    AuditEventService.stub(:log, ->(**) { raise ActiveRecord::RecordInvalid, invalid_event }) do
      post save_working_notes_evaluators_evaluation_path(@evaluation), params: {
        evaluation: { working_notes: 'Attempted outreach note' }
      }
    end

    assert_response :unprocessable_content
    assert_equal original_notes, @evaluation.reload.working_notes
    assert_select '#working-notes-form textarea', text: 'Attempted outreach note'
    assert_select '#working-notes-form [data-controller="error-summary"][tabindex="-1"]'
    assert_select '[role="alert"]', count: 1
    assert_select '#save-working-notes-errors', text: /Failed to save working notes:/
    assert_nil flash[:alert]
  end

  test 'unassigned evaluator and administrator cannot overwrite working notes' do
    [create(:evaluator), create(:admin)].each do |actor|
      sign_in_for_controller_test(actor)
      assert_no_difference('Event.where(action: "evaluation_working_notes_updated").count') do
        post save_working_notes_evaluators_evaluation_path(@evaluation), params: {
          evaluation: { working_notes: 'Unauthorized note' }
        }
      end
      assert_response :redirect
      assert_nil @evaluation.reload.working_notes
    end
  end

  test 'report preserves external recommendation details on rejection and submits without catalog recommendations' do
    @evaluation.update!(status: :scheduled, evaluation_date: 1.day.from_now)
    values = {
      appointment_completed_at: 1.hour.ago, location: 'Home', notes: 'Assessment observations',
      no_suitable_product: '1', recommendation_notes: ' ', products_tried_inputs: {},
      recommended_product_ids: ['']
    }
    post submit_report_evaluators_evaluation_path(@evaluation), params: { evaluation: values }

    assert_response :unprocessable_content
    assert_equal 'scheduled', @evaluation.reload.status
    assert_select '#complete_evaluation_no_suitable_product[checked]'
    assert_select 'textarea[name="evaluation[recommendation_notes]"]', text: ' '
    assert_select '#complete-evaluation-form [data-controller="error-summary"] a[href="#complete_evaluation_recommendation_notes"]'
    assert_select '#complete_evaluation_recommendation_notes[aria-invalid="true"]'
    assert_select '[role="alert"]', count: 1
    assert_nil flash[:alert]

    values[:no_suitable_product] = '0'
    values[:recommendation_notes] = 'Consider a switch-access device outside the program catalog.'
    post submit_report_evaluators_evaluation_path(@evaluation), params: { evaluation: values }
    assert_redirected_to evaluators_evaluation_path(@evaluation)
    @evaluation.reload
    assert_equal 'completed', @evaluation.status
    assert_equal 'outside_catalog', @evaluation.recommendation_outcome
    assert_equal values[:recommendation_notes], @evaluation.recommendation_notes
    assert_empty @evaluation.recommended_product_ids
    assert_empty @evaluation.products_tried
  end

  test 'invalid schedule attaches the error to the restored date field' do
    post schedule_evaluators_evaluation_path(@evaluation), params: {
      evaluation: { evaluation_date: 1.hour.ago.strftime('%Y-%m-%dT%H:%M'), location: 'Library', notes: 'Appointment agreed' }
    }

    assert_response :unprocessable_content
    assert_select '#schedule-evaluation-form [data-controller="error-summary"] a[href="#schedule_evaluation_evaluation_date"]'
    assert_select '#schedule_evaluation_evaluation_date[aria-invalid="true"]'
    assert_select '[role="alert"]', count: 1
    assert_select '#schedule-evaluation-form label[for="schedule_evaluation_evaluation_date"] .sr-only', text: /required/
    assert_nil flash[:alert]
    assert_nil @evaluation.reload.evaluation_date
  end

  test 'generic updates render one focused error in the visible form without changing ownership or status' do
    [[:requested, 'save-working-notes-errors'], [:scheduled, 'submit-report-errors'],
     [:completed, 'supplemental-notes-errors']].each do |status, summary_id|
      evaluation = create(:evaluation, evaluator: @evaluator, status: status,
                                       evaluation_date: (1.day.from_now unless status == :requested),
                                       appointment_completed_at: (1.hour.ago if status == :completed),
                                       report_submitted_at: (Time.current if status == :completed))
      original = evaluation.attributes
      other_application = create(:application)

      patch evaluators_evaluation_path(evaluation), params: {
        evaluation: { application_id: other_application.id, status: 'completed', notes: 'Forged report' }
      }

      assert_response :unprocessable_content
      assert_equal original, evaluation.reload.attributes
      assert_select "##{summary_id}[role=alert][tabindex='-1'][data-controller=error-summary]"
      assert_select '[role="alert"]', count: 1
      assert_includes response.body, 'This evaluation action must use the appropriate lifecycle control.'
      assert_nil flash[:alert]
    end
  end
end
