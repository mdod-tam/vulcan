# frozen_string_literal: true

require 'test_helper'

class ServiceDashboardSummaryTest < ActiveSupport::TestCase
  setup do
    @now = Time.current.change(usec: 0)
    @admin = create(:admin)
    @trainer = create(:trainer)
    @evaluator = create(:evaluator)
  end

  test 'training waits use assignment and scheduling audit clocks instead of the future appointment' do
    session = assigned_training(@now - 8.days)
    assert_equal 8, training_summary(session).fetch(:requested).oldest.days
    assert_equal :assignment, training_summary(session).fetch(:requested).oldest.clock
    assert_equal @trainer, training_summary(session).fetch(:requested).oldest.practitioner

    travel_to(@now - 5.days) do
      assert_predicate TrainingSessions::ScheduleService.new(session, @trainer, scheduled_for: @now + 10.days, location: 'Office').call, :success?
    end
    result = training_summary(session)

    assert_equal 0, result.fetch(:requested).count
    assert_equal 3.0, result.fetch(:requested).average_days
    assert_equal 1, result.fetch(:requested).sample_count
    assert_equal 1, result.fetch(:scheduled).count
    assert_equal 5, result.fetch(:scheduled).oldest.days
    assert_equal :scheduled, result.fetch(:scheduled).oldest.clock
    assert_equal @trainer, result.fetch(:scheduled).oldest.practitioner
    assert_nil result.fetch(:scheduled).average_days
  end

  test 'completed training averages scheduling to the actual completed visit rather than report submission' do
    session = assigned_training(@now - 10.days)
    travel_to(@now - 8.days) do
      assert_predicate TrainingSessions::ScheduleService.new(session, @trainer, scheduled_for: @now - 2.days, location: 'Office').call, :success?
    end
    product = create(:product)
    result = TrainingSessions::CompleteService.new(session, @trainer,
                                                   completed_at: @now - 2.days, constituent_summary: 'Practised the device controls.',
                                                   summary_locale: 'en', duration_hours: '1', product_trained_on_id: product.id).call
    assert_predicate result, :success?

    summary = training_summary(session).fetch(:scheduled)

    assert_equal 0, summary.count
    assert_equal 6.0, summary.average_days
    assert_equal 1, summary.sample_count
  end

  test 'covered requests wait from their new request and missing assignment clocks remain unknown' do
    unrecorded = create(:training_session, :requested, trainer: @trainer)
    pending = create(:application, :approved, assigned_trainer: @trainer, training_requested_at: @now - 3.days)
    result = ServiceDashboardSummary.new(TrainingSession.where(id: unrecorded.id), timings: ServiceDashboardSummary::TRAINING,
                                                                                   pending_requests: Application.with_pending_training_request.where(id: pending.id), now: @now).call

    summary = result.fetch(:requested)
    assert_equal 2, summary.count
    assert_equal pending, summary.oldest.application
    assert_equal @trainer, summary.oldest.practitioner
    assert_equal :request, summary.oldest.clock
    assert_equal 3, summary.oldest.days
    assert_equal 1, summary.unknown_dates
    assert_nil summary.average_days
    assert_equal 0, summary.sample_count
  end

  test 'evaluation reassignment uses its recorded operation and rescheduling starts the current scheduled wait' do
    application = create(:application, :approved, :with_all_proofs, application_date: Date.current)
    travel_to(@now - 10.days) { assert_predicate Applications::EvaluatorAssignment.assign(application, @evaluator, actor: @admin), :success? }
    evaluation = application.evaluations.sole
    assert_equal 10, evaluation_summary(evaluation).fetch(:requested).oldest.days
    replacement = create(:evaluator)
    travel_to(@now - 6.days) { assert_predicate Applications::EvaluatorAssignment.reassign(application, replacement, actor: @admin), :success? }
    evaluation.reload
    assert_equal 6, evaluation_summary(evaluation).fetch(:requested).oldest.days
    assert_equal replacement, evaluation_summary(evaluation).fetch(:requested).oldest.practitioner
    travel_to(@now - 4.days) do
      assert_predicate Evaluations::ScheduleService.new(evaluation, replacement, evaluation_date: @now + 5.days, location: 'Office').call, :success?
    end
    travel_to(@now - 1.day) do
      assert_predicate Evaluations::RescheduleService.new(evaluation, replacement, evaluation_date: @now + 8.days,
                                                                                   reschedule_reason: 'Constituent requested another day', location: 'Office').call, :success?
    end

    result = evaluation_summary(evaluation)
    assert_equal 2.0, result.fetch(:requested).average_days
    assert_equal 1, result.fetch(:requested).sample_count
    assert_equal 1, result.fetch(:scheduled).oldest.days
  end

  test 'evaluation completion averages and row scope exclude another evaluator and missing recorded schedules' do
    application = create(:application, :approved, :with_all_proofs, application_date: Date.current)
    travel_to(@now - 8.days) { assert_predicate Applications::EvaluatorAssignment.assign(application, @evaluator, actor: @admin), :success? }
    evaluation = application.evaluations.sole
    travel_to(@now - 6.days) do
      assert_predicate Evaluations::ScheduleService.new(evaluation, @evaluator, evaluation_date: @now - 2.days, location: 'Office').call, :success?
    end
    params = ActionController::Parameters.new(evaluation: { appointment_completed_at: @now - 2.days, notes: 'Completed assessment.',
                                                            no_suitable_product: '1', recommendation_notes: 'No suitable catalog product.' })
    assert_predicate Evaluations::SubmissionService.new(evaluation, params, actor: @evaluator).call, :success?
    other = create(:evaluation, :completed)
    unrecorded = create(:evaluation, :completed, evaluator: @evaluator)
    result = ServiceDashboardSummary.new(Evaluation.where(evaluator: @evaluator), timings: ServiceDashboardSummary::EVALUATION, now: @now).call

    assert_equal 4.0, result.fetch(:scheduled).average_days
    assert_equal 1, result.fetch(:scheduled).sample_count
    assert_equal 0, result.fetch(:scheduled).count
    assert_nil evaluation_summary(unrecorded).fetch(:scheduled).average_days
    assert_not_equal @evaluator.id, other.evaluator_id
  end

  test 'rapid successful reschedules retain every canonical booking event and the current wait clock' do
    session = assigned_training(@now - 3.days)
    application = create(:application, :approved, :with_all_proofs, application_date: Date.current)
    travel_to(@now - 3.days) { assert_predicate Applications::EvaluatorAssignment.assign(application, @evaluator, actor: @admin), :success? }
    evaluation = application.evaluations.sole
    travel_to(@now - 2.days) do
      assert_predicate TrainingSessions::ScheduleService.new(session, @trainer, scheduled_for: @now + 1.day, location: 'Office').call, :success?
      assert_predicate Evaluations::ScheduleService.new(evaluation, @evaluator, evaluation_date: @now + 1.day, location: 'Office').call, :success?
    end
    travel_to(@now - 1.day) do
      2.times do |index|
        date = @now + (index + 2).days
        assert_predicate TrainingSessions::RescheduleService.new(session, @trainer, scheduled_for: date,
                                                                                    reschedule_reason: 'Another appointment requested', location: 'Office').call, :success?
        assert_predicate Evaluations::RescheduleService.new(evaluation, @evaluator, evaluation_date: date,
                                                                                    reschedule_reason: 'Another appointment requested', location: 'Office').call, :success?
      end
    end

    [[session, 'training_scheduled', 'training_rescheduled'], [evaluation, 'evaluation_scheduled', 'evaluation_rescheduled']].each do |record, scheduled, rescheduled|
      initial = Event.find_by!(auditable: record, action: scheduled)
      changes = Event.where(auditable: record, action: rescheduled).order(:id).to_a
      assert initial.metadata['operation_id'].present?
      assert_equal 2, changes.size
      assert_equal 2, changes.map { |event| event.metadata.fetch('operation_id') }.uniq.size
    end
    assert_equal 1, training_summary(session).fetch(:scheduled).oldest.days
    assert_equal 1, evaluation_summary(evaluation).fetch(:scheduled).oldest.days
    assert_equal 1, training_summary(session).fetch(:requested).sample_count
    assert_equal 1, evaluation_summary(evaluation).fetch(:requested).sample_count
  end

  private

  def assigned_training(at)
    application = create(:application, :approved, :with_all_proofs, application_date: Date.current)
    travel_to(at) { assert_predicate Applications::TrainerAssignment.assign(application, @trainer, actor: @admin), :success? }
    application.training_sessions.sole
  end

  def training_summary(session)
    ServiceDashboardSummary.new(TrainingSession.where(id: session.id), timings: ServiceDashboardSummary::TRAINING, now: @now).call
  end

  def evaluation_summary(evaluation)
    ServiceDashboardSummary.new(Evaluation.where(id: evaluation.id), timings: ServiceDashboardSummary::EVALUATION, now: @now).call
  end
end
