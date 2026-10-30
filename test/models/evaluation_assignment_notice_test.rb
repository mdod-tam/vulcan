# frozen_string_literal: true

require 'test_helper'

class EvaluationAssignmentNoticeTest < ActiveSupport::TestCase
  setup do
    Policy.find_or_create_by!(key: 'waiting_period_years').update!(value: 3)
    load_seeded_email_templates('evaluator_mailer_new_evaluation_assigned')
    ensure_system_audit_actor!
    @admin = create(:admin)
    @first = create(:evaluator)
    @second = create(:evaluator)
    @application = create(:application, status: :approved, application_date: Date.current)
    @old_adapter = EmailDelivery::MailDeliveryJob.queue_adapter
    EmailDelivery::MailDeliveryJob.queue_adapter = :test
    EmailDelivery::MailDeliveryJob.queue_adapter.enqueued_jobs.clear
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    EmailDelivery::MailDeliveryJob.queue_adapter.enqueued_jobs.clear
    EmailDelivery::MailDeliveryJob.queue_adapter = @old_adapter
  end

  def execute_queued_notices
    EmailDelivery::MailDeliveryJob.queue_adapter.enqueued_jobs.dup.each { |job| ActiveJob::Base.execute(job) }
  end

  test 'only the latest assignment is delivered, even when the evaluation returns to a former evaluator' do
    assert_predicate Applications::EvaluatorAssignment.assign(@application, @first, actor: @admin), :success?
    assert_predicate Applications::EvaluatorAssignment.reassign(@application, @second, actor: @admin), :success?
    assert_predicate Applications::EvaluatorAssignment.reassign(@application, @first, actor: @admin), :success?

    assert_difference -> { Event.where(action: EmailDelivery::Outcome::SUPPRESSED).count }, 2 do
      execute_queued_notices
    end

    assert_equal [[@first.email]], ActionMailer::Base.deliveries.map(&:to)
  end

  test 'a notice for an evaluator who lost evaluator access before delivery is not sent' do
    assert_predicate Applications::EvaluatorAssignment.assign(@application, @first, actor: @admin), :success?
    @first.update_columns(status: User.statuses[:suspended])

    assert_difference -> { Event.where(action: EmailDelivery::Outcome::SUPPRESSED).count }, 1 do
      execute_queued_notices
    end

    assert_empty ActionMailer::Base.deliveries
  end

  test 'the notice names the operation that created or transferred the evaluation' do
    assert_predicate Applications::EvaluatorAssignment.assign(@application, @first, actor: @admin), :success?
    evaluation = @application.latest_evaluation
    assigned = Event.find_by!(action: 'evaluator_assigned', auditable: @application)
    assert_equal evaluation.assignment_operation_id, assigned.metadata['operation_id']

    assert_predicate Applications::EvaluatorAssignment.reassign(@application, @second, actor: @admin), :success?
    reassigned = Event.find_by!(action: 'evaluator_reassigned', auditable: evaluation)
    assert_equal evaluation.reload.assignment_operation_id, reassigned.metadata['operation_id']
    assert_not_equal assigned.metadata['operation_id'], reassigned.metadata['operation_id']
  end
end
