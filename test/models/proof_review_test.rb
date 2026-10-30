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
end
