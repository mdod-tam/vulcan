# frozen_string_literal: true

require 'test_helper'

# ProofReview#record! counts each rejection and archives the application past the limit, in the same
# transaction as the decision. The notices come from ProofDecisionFollowUp, which the writers run once their
# transaction has committed.
class ProofReviewRejectionLimitTest < ActiveSupport::TestCase
  include ProofResubmissionTestHelper
  include ActiveJob::TestHelper

  setup do
    @admin = create(:admin)
    @application = create(:application, :in_progress, skip_proofs: true)
    @application.income_proof.attach(io: StringIO.new('income proof content'), filename: 'income.pdf', content_type: 'application/pdf')
    @application.residency_proof.attach(io: StringIO.new('residency proof content'), filename: 'residency.pdf', content_type: 'application/pdf')
  end

  test 'a new rejection counts toward the limit' do
    assert_difference -> { @application.reload.total_rejections }, 1 do
      reject(:income)
    end
  end

  test 'a new rejection of the same proof preserves its earlier decision and counts again' do
    first = reject(:income)

    assert_difference -> { ProofReview.count }, 1 do
      assert_difference -> { @application.reload.total_rejections }, 1 do
        reject(:income, reason: 'Still unreadable')
      end
    end
    assert_equal 'Unreadable', first.reload.rejection_reason
  end

  test 'approvals and disability certification rejections do not count' do
    record_proof_review(application: @application, proof_type: :income, status: :approved, admin: @admin)
    record_proof_review(application: @application, proof_type: :disability_certification, status: :rejected, admin: @admin, rejection_reason: 'Illegible')

    assert_equal 0, @application.reload.total_rejections
  end

  test 'the rejection that reaches the limit warns an administrator and keeps the application open' do
    @application.update!(total_rejections: ProofReview::MAX_REJECTIONS - 1)
    assert_equal 2, @application.proof_submission_attempts_remaining

    assert_difference -> { Event.where(action: 'max_rejections_warning', auditable: @application).count }, 1 do
      assert_difference -> { Notification.where(action: 'max_rejections_warning', notifiable: @application).count }, 1 do
        reject(:income)
      end
    end

    assert_equal ProofReview::MAX_REJECTIONS, @application.reload.total_rejections
    assert_not_predicate @application, :status_archived?
    assert_equal 1, @application.proof_submission_attempts_remaining
    notification = Notification.find_by!(action: 'max_rejections_warning', notifiable: @application)
    assert_equal @admin.id, notification.recipient_id
    assert_equal @admin.id, notification.actor_id
    assert_nil notification.delivery_status
    assert_max_rejections_mail_count 0
  end

  %i[in_progress rejected].each do |initial_status|
    test "the rejection past the limit archives from #{initial_status} and queues the notice after commit" do
      @application.transition_status!(initial_status, actor: @admin)
      @application.update!(total_rejections: ProofReview::MAX_REJECTIONS)

      assert_difference -> { ApplicationStatusChange.count }, 1 do
        assert_difference -> { Event.where(action: 'application_status_changed').count }, 1 do
          reject(:income, reason: 'Final rejection')
        end
      end

      @application.reload
      assert_predicate @application, :status_archived?
      assert_equal ProofReview::MAX_REJECTIONS + 1, @application.total_rejections
      assert_equal 0, @application.proof_submission_attempts_remaining

      status_change = @application.status_changes.last
      assert_equal initial_status.to_s, status_change.from_status
      assert_equal 'archived', status_change.to_status
      assert_equal @admin, status_change.user
      assert_equal 'Application archived after exceeding maximum proof rejections', status_change.notes
      assert_equal 'max_proof_rejections', status_change.metadata['trigger']

      audit_event = @application.events.where(action: 'application_status_changed').last
      assert_equal @admin, audit_event.user
      assert_equal 'max_proof_rejections', audit_event.metadata['trigger']

      notification = Notification.find_by!(action: 'max_rejections_reached', notifiable: @application)
      assert_equal @application.user, notification.recipient
      assert_equal @admin, notification.actor
      assert_equal 'queued', notification.delivery_status
      assert_equal @application.proof_reviews.rejections.sole.id, notification.metadata['proof_review_id']
      assert_max_rejections_mail_count 1
    end
  end

  test 'the rejection that archives the application is audited but issues no upload link' do
    @application.update!(total_rejections: ProofReview::MAX_REJECTIONS)

    assert_difference -> { Event.where(action: 'proof_rejected', auditable: @application).count }, 1 do
      assert_no_difference ['SecureRequestForm.count',
                            "Event.where(action: 'proof_resubmission_request_failed').count"] do
        reject(:income)
      end
    end

    assert_predicate @application.reload, :status_archived?
  end

  test 'a failure while archiving rolls back the decision and the count' do
    @application.update!(total_rejections: ProofReview::MAX_REJECTIONS)
    Application.any_instance.stubs(:transition_status!).raises(ActiveRecord::RecordInvalid.new(@application))

    assert_no_difference ['ProofReview.count', 'ApplicationStatusChange.count'] do
      assert_raises(ActiveRecord::RecordInvalid) { reject(:income) }
    end

    assert_equal ProofReview::MAX_REJECTIONS, @application.reload.total_rejections
    assert_equal 'in_progress', @application.status
    assert_max_rejections_mail_count 0
  end

  test 'a failure while counting rolls back a repeat decision' do
    original = reject(:income)
    original_reason = original.reload.rejection_reason
    ProofReview.any_instance.stubs(:count_rejection!).raises(StandardError, 'count failed')

    assert_raises(StandardError) { reject(:income, reason: 'Changed reason') }

    assert_equal original_reason, original.reload.rejection_reason
    assert_equal 1, @application.reload.total_rejections
  end

  test 'a failed staff warning does not skip the committed archive notice' do
    @application.update!(total_rejections: ProofReview::MAX_REJECTIONS)
    original_log = AuditEventService.method(:log)
    fail_staff_warning = lambda do |**attributes|
      raise StandardError, 'warning failed' if attributes[:action] == 'max_rejections_warning'

      original_log.call(**attributes)
    end

    AuditEventService.stub(:log, fail_staff_warning) do
      assert_difference -> { ProofReview.count }, 1 do
        reject(:income)
      end
    end

    assert_equal ProofReview::MAX_REJECTIONS + 1, @application.reload.total_rejections
    assert_predicate @application, :status_archived?
    assert_equal 'queued', Notification.find_by!(notifiable: @application, action: 'max_rejections_reached').delivery_status
    assert_max_rejections_mail_count 1
  end

  private

  # Records the rejection and follows up on it, as the writers do once their transaction commits.
  def reject(proof_type, reason: 'Unreadable')
    review = record_proof_review(application: @application, proof_type: proof_type, status: :rejected, admin: @admin, rejection_reason: reason)
    Applications::ProofDecisionFollowUp.new(review).call
    review
  end

  def max_rejections_mail_jobs
    enqueued_jobs.select do |job|
      job[:job] == EmailDelivery::MailDeliveryJob && job[:args].first(2) == %w[ApplicationNotificationsMailer max_rejections_reached]
    end
  end

  def assert_max_rejections_mail_count(count)
    assert_equal count, max_rejections_mail_jobs.size
  end
end
