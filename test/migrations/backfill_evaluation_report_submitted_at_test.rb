# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/migrate/20261012120100_backfill_evaluation_report_submitted_at'

class BackfillEvaluationReportSubmittedAtTest < ActiveSupport::TestCase
  setup do
    @evaluator = create(:evaluator)
    @application = create(:application)
    @migration = BackfillEvaluationReportSubmittedAt.new
  end

  test 'restores the earliest recorded completion time without changing other report or application data' do
    evaluation = legacy_evaluation
    earliest = 2.days.ago.change(usec: 123_456)
    log_completion(evaluation, created_at: 1.day.ago)
    log_completion(evaluation, created_at: earliest)
    original = evaluation.attributes.except('report_submitted_at')
    application_attributes = @application.reload.attributes
    recommendations = evaluation.recommended_product_ids

    assert_no_difference(['Event.count', 'Notification.count']) do
      assert_no_enqueued_jobs { @migration.up }
    end

    assert_equal earliest, evaluation.reload.report_submitted_at
    assert_equal original, evaluation.attributes.except('report_submitted_at')
    assert_nil evaluation.appointment_completed_at
    assert_equal application_attributes, @application.reload.attributes
    assert_equal recommendations, evaluation.recommended_product_ids
  end

  test 'keeps an existing submission timestamp even when an earlier completion event exists' do
    evaluation = legacy_evaluation
    known_submission = 1.day.ago
    evaluation.update_columns(report_submitted_at: known_submission)
    log_completion(evaluation, created_at: 2.days.ago)
    original = evaluation.reload.attributes

    @migration.up

    assert_equal original, evaluation.reload.attributes
  end

  test 'completed reports with no completion audit remain unknown' do
    evaluation = legacy_evaluation
    original = evaluation.attributes

    @migration.up

    assert_equal original, evaluation.reload.attributes
    assert_nil evaluation.report_submitted_at
  end

  test 'metadata-only events and events belonging to another auditable cannot prove submission' do
    evaluation = legacy_evaluation
    metadata = { evaluation_id: evaluation.id, application_id: evaluation.application_id }
    Event.create!(user: @evaluator, action: 'evaluation_completed', metadata: metadata, created_at: 1.day.ago)
    Event.create!(user: @evaluator, action: 'evaluation_completed', auditable: @application,
                  metadata: metadata, created_at: 1.day.ago)
    original = evaluation.attributes

    @migration.up

    assert_equal original, evaluation.reload.attributes
  end

  test 'wrong action or conflicting evaluation and application ids do not backfill a completed report' do
    evaluation = legacy_evaluation
    metadata = { evaluation_id: evaluation.id, application_id: evaluation.application_id }
    Event.create!(user: @evaluator, action: 'evaluation_scheduled', auditable: evaluation,
                  metadata: metadata, created_at: 1.day.ago)
    Event.create!(user: @evaluator, action: 'evaluation_completed', auditable: evaluation,
                  metadata: metadata.merge(evaluation_id: evaluation.id + 1), created_at: 1.day.ago)
    Event.create!(user: @evaluator, action: 'evaluation_completed', auditable: evaluation,
                  metadata: metadata.merge(application_id: evaluation.application_id + 1), created_at: 1.day.ago)
    original = evaluation.attributes

    @migration.up

    assert_equal original, evaluation.reload.attributes
  end

  test 'matching completion audit does not complete an unfinished evaluation' do
    evaluation = create(:evaluation, status: :scheduled, evaluator: @evaluator,
                                     application: @application, constituent: @application.user)
    log_completion(evaluation, created_at: Time.current)
    original = evaluation.attributes

    @migration.up

    assert_equal original, evaluation.reload.attributes
  end

  test 'numeric and string metadata ids identify the same canonical event owner' do
    %i[number string].each do |format|
      evaluation = legacy_evaluation
      submitted_at = 1.day.ago.change(nsec: 123_456_789)
      metadata = { evaluation_id: evaluation.id, application_id: evaluation.application_id }
      metadata.transform_values!(&:to_s) if format == :string
      completion = AuditEventService.log(action: 'evaluation_completed', actor: @evaluator, auditable: evaluation,
                                         metadata: metadata, created_at: submitted_at)

      @migration.up

      assert_equal completion.reload.created_at, evaluation.reload.report_submitted_at
    end
  end

  test 'repeating up and rolling down preserve recovered history and the original updated time' do
    evaluation = legacy_evaluation
    submitted_at = 1.day.ago.change(nsec: 123_456_789)
    completion = log_completion(evaluation, created_at: submitted_at)
    @migration.up
    recovered = evaluation.reload.attributes
    log_completion(evaluation, created_at: 2.days.ago)

    @migration.up
    @migration.down

    assert_equal recovered, evaluation.reload.attributes
    assert_equal completion.reload.created_at, evaluation.report_submitted_at
  end

  private

  def legacy_evaluation
    evaluation = create(:evaluation, :completed, evaluator: @evaluator,
                                                 application: @application, constituent: @application.user)
    # Reproduce the stored pre-column report, including an unrelated later edit.
    evaluation.update_columns(appointment_completed_at: nil, report_submitted_at: nil,
                              evaluation_date: 4.days.ago, created_at: 1.month.ago, updated_at: 1.hour.ago)
    evaluation.reload
  end

  def log_completion(evaluation, created_at:)
    AuditEventService.log(
      action: 'evaluation_completed', actor: @evaluator, auditable: evaluation, created_at: created_at,
      metadata: { evaluation_id: evaluation.id, application_id: evaluation.application_id,
                  evaluation_date: evaluation.evaluation_date&.iso8601, timestamp: 1.year.ago.iso8601 }
    )
  end
end
