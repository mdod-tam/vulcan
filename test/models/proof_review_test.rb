# frozen_string_literal: true

require 'test_helper'

class ProofReviewTest < ActiveSupport::TestCase
  include ProofRejectionNotificationAssertions

  def setup
    @admin = create(:admin)
    @application = create(:application, :in_progress, skip_proofs: true)

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

    build(:proof_review,
          application: @application,
          admin: @admin,
          proof_type: :income,
          status: :approved)

    # Manually update the application status
    @application.update!(income_proof_status: :approved)

    @application.reload
    assert @application.income_proof_status_approved?
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
    assert_not Notification.exists?(notifiable: @application, action: 'income_proof_rejected')
  ensure
    Current.reset
  end
end
