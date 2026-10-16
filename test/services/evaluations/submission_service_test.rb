# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class SubmissionServiceTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @evaluator = create(:evaluator)
      @product = create(:product, name: 'Accessible Tablet')
      @evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled, evaluation_date: 1.day.from_now)
      load_seeded_email_templates('evaluator_mailer_evaluation_submission_confirmation')
      ActionMailer::Base.deliveries.clear
    end

    test 'submits evaluation, logs evaluation_completed, and delivers the confirmation' do
      assert_difference('Event.where(action: "evaluation_completed").count', 1) do
        perform_enqueued_jobs do
          result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

          assert result.success?
        end
      end

      assert_equal [[@evaluation.constituent.email]], ActionMailer::Base.deliveries.map(&:to)

      @evaluation.reload
      event = Event.order(:created_at).last

      assert_equal 'completed', @evaluation.status
      assert_equal @evaluation.id, event.metadata['evaluation_id']
      assert_equal @evaluation.application_id, event.metadata['application_id']
      assert_equal 1, event.metadata['products_tried_count']
      assert_equal 1, event.metadata['recommended_products_count']
      assert_includes event.metadata['recommended_product_names'], 'Accessible Tablet'
    end

    test 'submits confirmed evaluation' do
      @evaluation.update!(status: :confirmed)

      assert_difference('Event.where(action: "evaluation_completed").count', 1) do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.success?
      end

      assert_equal 'completed', @evaluation.reload.status
    end

    test 'mixed recommendations preserve catalog IDs and other details while initializing only catalog needs' do
      parameters = submission_params
      parameters[:evaluation][:recommendation_notes] = 'Also consult an external communication specialist.'
      parameters[:evaluation][:products_tried_inputs][@product.id.to_s][:reaction] = 'Neutral'

      result = SubmissionService.new(@evaluation, parameters, actor: @evaluator).call

      assert result.success?, result.message
      assert_equal 'catalog_products', @evaluation.reload.recommendation_outcome
      assert_equal [@product.id], @evaluation.recommended_product_ids
      assert_equal 'Also consult an external communication specialist.', @evaluation.recommendation_notes
      assert_equal [{ 'product_id' => @product.id.to_s, 'reaction' => 'Neutral' }], @evaluation.products_tried
      assert_equal [@product.id], @evaluation.application.equipment_needs.pluck(:product_id)
    end

    test 'missing and invalid checked trial ratings roll back reports needs and audits' do
      original = @evaluation.attributes
      [nil, '', 'Not recorded', 'Unexpected'].each do |reaction|
        parameters = submission_params
        parameters[:evaluation][:products_tried_inputs][@product.id.to_s][:reaction] = reaction
        assert_no_enqueued_jobs do
          assert_no_difference ['EquipmentNeed.count', 'Event.count'] do
            result = SubmissionService.new(@evaluation, parameters, actor: @evaluator).call
            assert result.failure?
            assert_includes @evaluation.errors[:products_tried].join, reaction.blank? ? 'requires a satisfaction rating' : 'must use Satisfied'
          end
        end
        assert_equal original, @evaluation.reload.attributes
        assert_nil @evaluation.application.reload.equipment_needs_initialized_at
      end
    end

    test 'trial parameters permit only selected and reaction within numeric product rows' do
      parameters = submission_params
      parameters[:evaluation][:products_tried_inputs][@product.id.to_s][:internal] = 'untrusted'
      permitted = SubmissionService.report_params(parameters).to_h

      assert_equal({ @product.id.to_s => { 'selected' => '1', 'reaction' => 'Satisfied' } }, permitted['products_tried_inputs'])
    end

    test 'report completion clears review bookkeeping and initializes needs without resubmitting historical intake' do
      application = @evaluation.application
      application.update_columns(maryland_resident: false, needs_review_since: 1.day.ago)
      original = application.reload.attributes.except('needs_review_since', 'equipment_needs_initialized_at', 'updated_at')
      assert_not application.valid?

      assert_difference 'Event.where(action: "evaluation_completed").count', 1 do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call
        assert result.success?, result.message
      end

      assert_equal 'completed', @evaluation.reload.status
      assert_nil application.reload.needs_review_since
      assert application.equipment_needs_initialized_at
      assert_equal original, application.attributes.except('needs_review_since', 'equipment_needs_initialized_at', 'updated_at')
      assert_equal [@product.id], application.equipment_needs.pluck(:product_id)
      assert_equal 1, application.events.where(action: 'equipment_needs_initialized').count
    end

    test 'empty recommendation controls cannot use the stored catalog default to complete a report' do
      [:omitted, nil, '', ' '].each do |choice|
        parameters = submission_params
        parameters[:evaluation].delete(:recommended_product_ids)
        if choice == :omitted
          parameters[:evaluation].delete(:no_suitable_product)
        else
          parameters[:evaluation][:no_suitable_product] = choice
        end
        original = @evaluation.reload.attributes

        assert_no_enqueued_jobs do
          assert_no_difference('Event.where(action: "evaluation_completed").count') do
            result = SubmissionService.new(@evaluation, parameters, actor: @evaluator).call

            assert result.failure?
            assert_includes @evaluation.errors[:recommended_products].join, 'must be selected'
          end
        end
        assert_equal original, @evaluation.reload.attributes
      end
    end

    test 'email configuration refusal at enqueue keeps the completed evaluation' do
      ensure_system_audit_actor!
      FeatureFlag.find_by!(name: EmailDelivery.category_control('evaluation')).destroy!

      result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call
      assert result.success?
      assert_equal :configuration_error, result.data[:notification]
      perform_enqueued_jobs

      assert_equal 'completed', @evaluation.reload.status
      assert Event.exists?(action: EmailDelivery::Outcome::CONFIGURATION_ERROR)
      assert_not Event.exists?(action: EmailDelivery::Outcome::SUPPRESSED)
      assert_empty ActionMailer::Base.deliveries
    end

    test 'does not submit requested evaluation' do
      @evaluation.update!(status: :requested, evaluation_date: nil)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
        assert_equal 'Only scheduled or confirmed evaluations can be completed.', result.message
      end

      assert_equal 'requested', @evaluation.reload.status
    end

    test 'does not submit no-show evaluation' do
      @evaluation.update!(status: :no_show)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
        assert_equal 'Only scheduled or confirmed evaluations can be completed.', result.message
      end

      assert_equal 'no_show', @evaluation.reload.status
    end

    test 'does not submit already completed evaluation' do
      @evaluation.update!(status: :completed, appointment_completed_at: Time.current, report_submitted_at: Time.current)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
        assert_equal 'Only scheduled or confirmed evaluations can be completed.', result.message
      end

      assert_equal 'completed', @evaluation.reload.status
    end

    test 'does not submit cancelled evaluation' do
      @evaluation.update!(status: :cancelled)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
      end

      assert_equal 'cancelled', @evaluation.reload.status
    end

    test 'preserves scheduled time and records actual appointment and server submission times' do
      scheduled_time = @evaluation.evaluation_date

      travel_to(Time.current.change(usec: 0)) do
        actual_time = 3.hours.ago
        parameters = submission_params
        parameters[:evaluation][:appointment_completed_at] = actual_time
        parameters[:evaluation][:evaluation_date] = 10.days.ago
        parameters[:evaluation][:report_submitted_at] = 10.days.ago

        result = SubmissionService.new(@evaluation, parameters, actor: @evaluator).call

        assert result.success?
        @evaluation.reload
        assert_in_delta scheduled_time, @evaluation.evaluation_date, 1.second
        assert_equal actual_time, @evaluation.appointment_completed_at
        assert_equal Time.current, @evaluation.report_submitted_at

        event = Event.find_by!(action: 'evaluation_completed', auditable: @evaluation)
        assert_equal scheduled_time.iso8601, event.metadata['evaluation_date']
        assert_equal actual_time.iso8601, event.metadata['appointment_completed_at']
        assert_equal Time.current.iso8601, event.metadata['report_submitted_at']
      end
    end

    test 'missing or future actual appointment leaves report and submission timestamps unchanged' do
      [nil, 1.day.from_now].each do |actual_time|
        parameters = submission_params
        parameters[:evaluation][:appointment_completed_at] = actual_time

        assert_no_difference('Event.where(action: "evaluation_completed").count') do
          result = SubmissionService.new(@evaluation.reload, parameters, actor: @evaluator).call

          assert result.failure?
          assert_includes result.message, 'Appointment completed at'
        end

        @evaluation.reload
        assert_equal 'scheduled', @evaluation.status
        assert_nil @evaluation.appointment_completed_at
        assert_nil @evaluation.report_submitted_at
      end
    end

    test 'stale second submission cannot replace the completed report or its timestamps' do
      stale_evaluation = Evaluation.find(@evaluation.id)
      first_result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call
      assert first_result.success?
      @evaluation.reload
      original_submission_time = @evaluation.report_submitted_at
      parameters = submission_params
      parameters[:evaluation][:notes] = 'Attempted replacement report'

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        second_result = SubmissionService.new(stale_evaluation, parameters, actor: @evaluator).call

        assert second_result.failure?
      end

      @evaluation.reload
      assert_equal 'completed', @evaluation.status
      assert_equal 'Completed evaluation', @evaluation.notes
      assert_equal original_submission_time, @evaluation.report_submitted_at
    end

    test 'stale assigned evaluator cannot submit after the assignment changes' do
      stale_evaluation = Evaluation.find(@evaluation.id)
      replacement = create(:evaluator)
      @evaluation.update!(evaluator: replacement)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(stale_evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
        assert_equal 'Only the assigned evaluator can update this evaluation.', result.message
      end

      @evaluation.reload
      assert_equal replacement.id, @evaluation.evaluator_id
      assert_equal 'scheduled', @evaluation.status
      assert_nil @evaluation.report_submitted_at
    end

    test 'completion audit failure rolls back report timestamps recommendations and application review change' do
      application = @evaluation.application
      application.update!(needs_review_since: Time.current)
      review_time = application.reload.needs_review_since
      original_notes = @evaluation.notes
      original_recommendations = @evaluation.recommended_product_ids
      invalid_event = Event.new
      failing_audit = ->(**_attributes) { raise ActiveRecord::RecordInvalid, invalid_event }

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        AuditEventService.stub(:log, failing_audit) do
          result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

          assert result.failure?
        end
      end

      @evaluation.reload
      assert_equal 'scheduled', @evaluation.status
      assert_nil @evaluation.appointment_completed_at
      assert_nil @evaluation.report_submitted_at
      assert_equal original_notes, @evaluation.notes
      assert_equal original_recommendations.sort, @evaluation.recommended_product_ids.sort
      assert_equal review_time, application.reload.needs_review_since
    end

    test 'noncatalog outcomes commit truthful reports and clear omitted old catalog recommendations' do
      %w[outside_catalog no_suitable_product].each do |outcome|
        evaluation = create(
          :evaluation,
          evaluator: @evaluator,
          status: :scheduled,
          evaluation_date: 1.day.from_now,
          working_notes: 'Private outreach arrangements'
        )
        scheduled_time = evaluation.evaluation_date
        parameters = submission_params
        parameters[:evaluation][:no_suitable_product] = outcome == 'no_suitable_product' ? '1' : '0'
        parameters[:evaluation][:recommendation_notes] = 'Assessment reason and any external product details'
        parameters[:evaluation].delete(:recommended_product_ids)
        parameters[:evaluation][:products_tried_inputs] = {}

        assert_difference('Event.where(action: "evaluation_completed").count', 1) do
          result = SubmissionService.new(evaluation, parameters, actor: @evaluator).call

          assert result.success?
        end

        evaluation.reload
        assert_equal 'completed', evaluation.status
        assert_equal outcome, evaluation.recommendation_outcome
        assert_equal 'Assessment reason and any external product details', evaluation.recommendation_notes
        assert_empty evaluation.recommended_products
        assert_empty evaluation.products_tried
        assert_equal scheduled_time, evaluation.evaluation_date
        assert evaluation.appointment_completed_at.present?
        assert evaluation.report_submitted_at.present?
        assert_equal 'Private outreach arrangements', evaluation.working_notes

        event = Event.find_by!(action: 'evaluation_completed', auditable: evaluation)
        assert_equal @evaluator.id, event.user_id
        assert_equal outcome, event.metadata['recommendation_outcome']
        assert_equal 0, event.metadata['recommended_products_count']
        assert_equal 0, event.metadata['products_tried_count']
        assert_equal evaluation.appointment_completed_at.iso8601, event.metadata['appointment_completed_at']
        assert_equal evaluation.report_submitted_at.iso8601, event.metadata['report_submitted_at']
        assert_not_includes event.metadata.to_json, 'Private outreach arrangements'
      end
    end

    test 'no suitable product contradicts catalog recommendations and rolls back the report' do
      original_recommendations = @evaluation.recommended_product_ids
      parameters = submission_params
      parameters[:evaluation][:no_suitable_product] = '1'
      parameters[:evaluation][:recommendation_notes] = 'External device recommendation'

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, parameters, actor: @evaluator).call

        assert result.failure?
        assert_includes @evaluation.errors[:no_suitable_product], 'cannot be combined with catalog recommendations'
      end

      @evaluation.reload
      assert_equal 'scheduled', @evaluation.status
      assert_equal 'catalog_products', @evaluation.recommendation_outcome
      assert_nil @evaluation.recommendation_notes
      assert_nil @evaluation.appointment_completed_at
      assert_nil @evaluation.report_submitted_at
      assert_equal original_recommendations.sort, @evaluation.recommended_product_ids.sort
    end

    test 'missing noncatalog explanation restores prior products outcome and application review state' do
      application = @evaluation.application
      application.update!(needs_review_since: Time.current)
      review_time = application.reload.needs_review_since
      original_recommendations = @evaluation.recommended_product_ids
      original_tried = @evaluation.products_tried
      parameters = submission_params
      parameters[:evaluation][:no_suitable_product] = '1'
      parameters[:evaluation][:recommendation_notes] = ''
      parameters[:evaluation].delete(:recommended_product_ids)
      parameters[:evaluation][:products_tried_inputs] = {}

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, parameters, actor: @evaluator).call

        assert result.failure?
        assert_includes result.message, 'Recommendation notes'
      end

      @evaluation.reload
      assert_equal 'scheduled', @evaluation.status
      assert_equal 'catalog_products', @evaluation.recommendation_outcome
      assert_nil @evaluation.recommendation_notes
      assert_nil @evaluation.appointment_completed_at
      assert_nil @evaluation.report_submitted_at
      assert_equal original_recommendations.sort, @evaluation.recommended_product_ids.sort
      assert_equal original_tried, @evaluation.products_tried
      assert_equal review_time, application.reload.needs_review_since
    end

    test 'a submitted outcome cannot override the recommendation controls' do
      parameters = submission_params
      parameters[:evaluation][:recommendation_outcome] = 'unrecognized_outcome'

      assert_difference('Event.where(action: "evaluation_completed").count', 1) do
        result = SubmissionService.new(@evaluation, parameters, actor: @evaluator).call

        assert result.success?, result.message
      end

      assert_equal 'completed', @evaluation.reload.status
      assert_equal 'catalog_products', @evaluation.recommendation_outcome
      assert @evaluation.report_submitted_at
    end

    test 'noncatalog report still rechecks current assignment before saving its outcome' do
      replacement = create(:evaluator)
      parameters = submission_params
      parameters[:evaluation][:no_suitable_product] = '1'
      parameters[:evaluation][:recommendation_notes] = 'No suitable device'
      parameters[:evaluation].delete(:recommended_product_ids)

      assert_no_difference('Event.where(action: "evaluation_completed").count') do
        result = SubmissionService.new(@evaluation, parameters, actor: replacement).call

        assert result.failure?
      end

      assert_equal 'scheduled', @evaluation.reload.status
      assert_equal 'catalog_products', @evaluation.recommendation_outcome
    end

    test 'assigned administrator records outside consultation from requested without an invented appointment or trials' do
      admin = create(:admin)
      @evaluation.update!(evaluator: admin, status: :requested, evaluation_date: nil, location: nil)
      parameters = submission_params
      parameters[:evaluation][:assessment_source] = 'outside_specialist'
      parameters[:evaluation][:location] = ''
      parameters[:evaluation][:products_tried_inputs] = {}
      parameters[:evaluation][:notes] = 'Recommendations from the outside specialist consultation and written assessment.'

      travel_to(Time.current.change(usec: 0)) do
        parameters[:evaluation][:appointment_completed_at] = 2.days.ago
        assert_difference('EquipmentNeed.count', 1) do
          result = SubmissionService.new(@evaluation, parameters, actor: admin).call

          assert result.success?, result.message
        end

        @evaluation.reload
        assert_equal 'completed', @evaluation.status
        assert_equal 'outside_specialist', @evaluation.assessment_source
        assert_nil @evaluation.evaluation_date
        assert_empty @evaluation.products_tried
        assert_equal 2.days.ago, @evaluation.appointment_completed_at
        assert_equal Time.current, @evaluation.report_submitted_at
        assert_equal Time.current, @evaluation.application.reload.equipment_needs_initialized_at
        need = @evaluation.application.equipment_needs.sole
        assert_equal @product.id, need.product_id
        assert_equal 1, need.remaining_quantity
        assert_equal @evaluation.id, need.source_evaluation_id
        event = Event.find_by!(action: 'evaluation_completed', auditable: @evaluation)
        assert_equal 'outside_specialist', event.metadata['assessment_source']
        assert_equal admin.id, event.user_id
      end
    end

    test 'ordinary evaluator cannot forge outside specialist source even for a scheduled evaluation' do
      parameters = submission_params
      parameters[:evaluation][:assessment_source] = 'outside_specialist'
      parameters[:evaluation][:products_tried_inputs] = {}

      assert_no_difference(['EquipmentNeed.count', 'Event.where(action: "evaluation_completed").count']) do
        result = SubmissionService.new(@evaluation, parameters, actor: @evaluator).call

        assert result.failure?
        assert_includes result.message, 'assigned administrator'
      end

      assert_equal 'direct_assessment', @evaluation.reload.assessment_source
      assert_equal 'scheduled', @evaluation.status
    end

    test 'outside consultation still needs written context and an actual completion time' do
      admin = create(:admin)
      @evaluation.update!(evaluator: admin, status: :requested, evaluation_date: nil)
      parameters = submission_params
      parameters[:evaluation][:assessment_source] = 'outside_specialist'
      parameters[:evaluation][:notes] = ''
      parameters[:evaluation][:appointment_completed_at] = nil
      parameters[:evaluation][:products_tried_inputs] = {}

      assert_no_difference(['EquipmentNeed.count', 'Event.where(action: "evaluation_completed").count']) do
        result = SubmissionService.new(@evaluation, parameters, actor: admin).call

        assert result.failure?
        assert_includes @evaluation.errors[:notes], "can't be blank"
        assert_includes @evaluation.errors[:appointment_completed_at], "can't be blank"
      end
      assert_equal 'requested', @evaluation.reload.status
      assert_nil @evaluation.application.reload.equipment_needs_initialized_at
    end

    test 'reassigned away administrator cannot complete a stale outside consultation' do
      admin = create(:admin)
      @evaluation.update!(evaluator: admin, status: :requested, evaluation_date: nil)
      stale_evaluation = Evaluation.find(@evaluation.id)
      @evaluation.update!(evaluator: create(:admin))
      parameters = submission_params
      parameters[:evaluation][:assessment_source] = 'outside_specialist'

      assert_no_difference(['EquipmentNeed.count', 'Event.where(action: "evaluation_completed").count']) do
        result = SubmissionService.new(stale_evaluation, parameters, actor: admin).call

        assert result.failure?
        assert_equal 'Only the assigned evaluator can update this evaluation.', result.message
      end
      assert_equal 'requested', @evaluation.reload.status
    end

    test 'report completion rechecks approval on a previously loaded application' do
      application = @evaluation.application
      stale_evaluation = Evaluation.find(@evaluation.id)
      assert stale_evaluation.application.status_approved?
      application.transition_status!(:archived, actor: create(:admin))

      assert_no_difference(['EquipmentNeed.count', 'Event.where(action: "evaluation_completed").count']) do
        result = SubmissionService.new(stale_evaluation, submission_params, actor: @evaluator).call

        assert result.failure?
        assert_includes result.message, 'Only approved applications'
      end
      assert_equal 'scheduled', @evaluation.reload.status
      assert_nil @evaluation.report_submitted_at
    end

    test 'needs initialization failure rolls back the report audit and review state' do
      @evaluation.application.update!(needs_review_since: Time.current)
      original_review_time = @evaluation.application.reload.needs_review_since
      failing_initialization = ->(*) { raise ActiveRecord::RecordInvalid, EquipmentNeed.new }

      assert_no_difference(['EquipmentNeed.count', 'Event.where(action: "evaluation_completed").count']) do
        EquipmentNeeds::Writer.stub(:initialize_from!, failing_initialization) do
          result = SubmissionService.new(@evaluation, submission_params, actor: @evaluator).call

          assert result.failure?
        end
      end
      assert_equal 'scheduled', @evaluation.reload.status
      assert_nil @evaluation.report_submitted_at
      assert_nil @evaluation.application.reload.equipment_needs_initialized_at
      assert_equal original_review_time, @evaluation.application.needs_review_since
    end

    private

    def submission_params
      ActionController::Parameters.new(
        evaluation: {
          no_suitable_product: '0',
          notes: 'Completed evaluation',
          location: 'Main Office',
          appointment_completed_at: Time.current,
          recommended_product_ids: [@product.id],
          products_tried_inputs: { @product.id.to_s => { selected: '1', reaction: 'Satisfied' } },
          attendees_field: 'Test Constituent'
        }
      )
    end
  end
end
