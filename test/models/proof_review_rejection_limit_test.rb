# frozen_string_literal: true

require 'test_helper'

# ProofReview#record! counts each rejection and archives the application past the limit, in the same
# transaction as the decision. The notices come from ProofDecisionFollowUp, which the writers run once their
# transaction has committed.
class ProofReviewRejectionLimitTest < ActiveSupport::TestCase
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

  test 'a repeat rejection of the same proof updates its row and counts again' do
    reject(:income)

    assert_no_difference -> { ProofReview.count } do
      assert_difference -> { @application.reload.total_rejections }, 1 do
        reject(:income, reason: 'Still unreadable')
      end
    end
  end

  test 'approvals and disability certification rejections do not count' do
    ProofReview.for_decision(@application, proof_type: :income, status: :approved).record!(admin: @admin)
    ProofReview.for_decision(@application, proof_type: :disability_certification, status: :rejected)
               .record!(admin: @admin, rejection_reason: 'Illegible')

    assert_equal 0, @application.reload.total_rejections
  end

  test 'the rejection that reaches the limit warns an administrator and keeps the application open' do
    @application.update!(total_rejections: ProofReview::MAX_REJECTIONS - 1)

    assert_difference -> { Event.where(action: 'max_rejections_warning', auditable: @application).count }, 1 do
      assert_difference -> { Notification.where(action: 'max_rejections_warning', notifiable: @application).count }, 1 do
        reject(:income)
      end
    end

    assert_equal ProofReview::MAX_REJECTIONS, @application.reload.total_rejections
    assert_not_predicate @application, :status_archived?
    notification = Notification.find_by!(action: 'max_rejections_warning', notifiable: @application)
    assert_equal @admin.id, notification.recipient_id
    assert_equal @admin.id, notification.actor_id
    assert_nil notification.delivery_status
    assert_max_rejections_mail_count 0
  end

  test 'the rejection past the limit archives the application and queues the notice after the commit' do
    @application.update!(total_rejections: ProofReview::MAX_REJECTIONS)

    assert_difference -> { ApplicationStatusChange.count }, 1 do
      assert_difference -> { Event.where(action: 'application_status_changed').count }, 1 do
        reject(:income, reason: 'Final rejection')
      end
    end

    @application.reload
    assert_predicate @application, :status_archived?
    assert_equal ProofReview::MAX_REJECTIONS + 1, @application.total_rejections

    status_change = @application.status_changes.last
    assert_equal 'archived', status_change.to_status
    assert_equal @admin, status_change.user
    assert_equal 'Application archived after exceeding maximum proof rejections', status_change.notes
    assert_equal 'max_proof_rejections', status_change.metadata['trigger']

    audit_event = @application.events.where(action: 'application_status_changed').last
    assert_equal @admin, audit_event.user
    assert_equal 'max_proof_rejections', audit_event.metadata['trigger']

    assert_max_rejections_mail_count 1
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

  test 'a failed notice does not fail a review that has committed' do
    @application.update!(total_rejections: ProofReview::MAX_REJECTIONS - 1)
    Applications::ProofDecisionFollowUp.any_instance.stubs(:send_max_rejections_warning).raises(StandardError, 'warning failed')

    assert_difference -> { ProofReview.count }, 1 do
      reject(:income)
    end

    assert_equal ProofReview::MAX_REJECTIONS, @application.reload.total_rejections
  end

  private

  # Records the rejection and follows up on it, as the writers do once their transaction commits.
  def reject(proof_type, reason: 'Unreadable')
    review = ProofReview.for_decision(@application, proof_type: proof_type, status: :rejected)
                        .record!(admin: @admin, rejection_reason: reason)
    Applications::ProofDecisionFollowUp.new(review).call
    review
  end

  def max_rejections_mail_jobs
    enqueued_jobs.select do |job|
      job[:job] == EmailDelivery::MailDeliveryJob && job[:args].first(2) == %w[ApplicationNotificationsMailer max_rejections_reached]
    end
  end

  # The warning at the limit is delivered through the same mailer action as the archive notice,
  # so a rejection past the limit queues two.
  def assert_max_rejections_mail_count(count)
    assert_equal count, max_rejections_mail_jobs.size
  end
end
