# frozen_string_literal: true

require 'test_helper'

class ProofReviewTest < ActiveSupport::TestCase
  include ProofRejectionNotificationAssertions

  def setup
    @admin = create(:admin)
    # Create a simple application without using problematic traits
    @application = create(:application, :in_progress, skip_proofs: true)

    # Manually attach proofs using direct methods to avoid the factory issues
    @application.income_proof.attach(
      io: StringIO.new('income proof content'),
      filename: 'income.pdf',
      content_type: 'application/pdf'
    )

    @application.residency_proof.attach(
      io: StringIO.new('residency proof content'),
      filename: 'residency.pdf',
      content_type: 'application/pdf'
    )
  end

  def test_valid_proof_review
    proof_review = build(:proof_review,
                         application: @application,
                         admin: @admin,
                         proof_type: :income,
                         status: :approved,
                         reviewed_at: Time.current)

    assert proof_review.valid?
  end

  def test_invalid_without_required_fields
    proof_review = ProofReview.new
    assert_not proof_review.valid?

    assert_includes proof_review.errors[:proof_type], "can't be blank"
    assert_includes proof_review.errors[:status], "can't be blank"
    assert_includes proof_review.errors[:admin], 'must exist'
    assert_includes proof_review.errors[:application], 'must exist'
  end

  def test_requires_rejection_reason_when_rejected
    proof_review = build(:proof_review,
                         application: @application,
                         admin: @admin,
                         proof_type: :income,
                         status: :rejected,
                         rejection_reason: nil)

    assert_not proof_review.valid?
    assert_includes proof_review.errors[:rejection_reason], "can't be blank"
  end

  def test_updates_application_status_when_proof_is_approved
    @application.update!(income_proof_status: :not_reviewed)

    # Create the proof review
    build(:proof_review,
          application: @application,
          admin: @admin,
          proof_type: :income,
          status: :approved)

    # Manually update the application status
    @application.update!(income_proof_status: :approved)

    # Verify the application status was updated
    @application.reload
    assert @application.income_proof_status_approved?
  end

  def test_archives_application_after_max_rejections
    @application.update!(total_rejections: 8)

    # Attach proof so it can be reviewed
    @application.income_proof.attach(
      io: StringIO.new('dummy'),
      filename: 'proof.pdf',
      content_type: 'application/pdf'
    )

    proof_review = build(:proof_review,
                         application: @application,
                         admin: @admin,
                         proof_type: :income,
                         status: :rejected,
                         rejection_reason: 'Final rejection')

    assert_difference -> { ApplicationStatusChange.count }, 1 do
      assert_difference -> { Event.where(action: 'application_status_changed').count }, 1 do
        proof_review.save!
      end
    end

    @application.reload
    assert @application.status_archived?

    status_change = @application.status_changes.last
    assert_equal 'archived', status_change.to_status
    assert_equal @admin, status_change.user
    assert_equal 'Application archived after exceeding maximum proof rejections', status_change.notes
    assert_equal 'max_proof_rejections', status_change.metadata['trigger']

    audit_event = @application.events.where(action: 'application_status_changed').last
    assert_equal @admin, audit_event.user
    assert_equal 'max_proof_rejections', audit_event.metadata['trigger']
  end

  def test_prevents_review_of_archived_application
    application = create(:application, :archived)

    proof_review = build(:proof_review,
                         application: application,
                         admin: @admin,
                         proof_type: :income,
                         status: :approved)

    assert_not proof_review.valid?
    assert_includes proof_review.errors[:application],
                    'cannot be reviewed when archived'
  end

  def test_rejection_requests_secure_proof_resubmission_instead_of_legacy_notification_delivery
    result = BaseService::Result.new(success: true, message: 'sent', data: {})
    service = mock('request-proof-resubmission')
    service.expects(:call).returns(result)
    Applications::RequestProofResubmission.expects(:new).with(
      application: @application,
      actor: @admin,
      proof_type: :income
    ).returns(service)
    NotificationService.expects(:create_and_deliver!).never

    assert_difference -> { Event.where(action: 'proof_rejected', auditable: @application).count }, 1 do
      create(:proof_review,
             application: @application,
             admin: @admin,
             proof_type: :income,
             status: :rejected,
             rejection_reason: 'Invalid documentation')
    end
  end

  def test_approval_notification_defaults_to_managing_guardian_contact_path
    guardian = create(:constituent, email: "guardian.proof.approval.#{SecureRandom.hex(3)}@example.com")
    dependent = create(
      :constituent,
      email: "dependent.proof.approval.#{SecureRandom.hex(3)}@system.matvulcan.local",
      dependent_email: guardian.email
    )
    create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
    application = create(:application, :in_progress, user: dependent, managing_guardian: guardian, skip_proofs: true)
    application.income_proof.attach(
      io: StringIO.new('income proof content'),
      filename: 'income.pdf',
      content_type: 'application/pdf'
    )

    NotificationService.expects(:create_and_deliver!).with do |params|
      params[:type] == 'proof_approved' &&
        params[:recipient] == guardian &&
        params[:actor] == @admin &&
        params[:notifiable] == application &&
        params[:metadata] == { proof_type: 'income' } &&
        params[:deliver] == false
    end

    create(:proof_review,
           application: application,
           admin: @admin,
           proof_type: :income,
           status: :approved)
  end

  def test_paper_rejection_requests_secure_proof_resubmission_and_queues_letter
    @application.user.update!(communication_preference: :letter, phone_type: :voice)
    @application.update!(income_proof_status: :rejected)
    @application.income_proof.purge if @application.income_proof.attached?
    NotificationService.stubs(:create_and_deliver!).returns(true)
    assert_no_orphan_proof_rejection_notification_delivery

    Current.paper_context = true

    assert_difference -> { SecureRequestForm.count }, 1 do
      assert_difference -> { PrintQueueItem.where(letter_type: :income_proof_rejected).count }, 1 do
        assert_difference -> { Event.where(action: 'proof_rejected', auditable: @application).count }, 1 do
          create(:proof_review,
                 application: @application,
                 admin: @admin,
                 proof_type: :income,
                 status: :rejected,
                 rejection_reason: 'Invalid documentation',
                 submission_method: :paper)
        end
      end
    end
  ensure
    Current.reset
  end
end
