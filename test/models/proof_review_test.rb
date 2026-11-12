# frozen_string_literal: true

require 'test_helper'

class ProofReviewTest < ActiveSupport::TestCase
  def test_invalid_without_required_fields
    proof_review = ProofReview.new
    assert_not proof_review.valid?

    assert_includes proof_review.errors[:proof_type], "can't be blank"
    assert_includes proof_review.errors[:status], "can't be blank"
    assert_includes proof_review.errors[:admin], 'must exist'
    assert_includes proof_review.errors[:application], 'must exist'
  end

  def test_requires_rejection_reason_when_rejected
    application = create(:application, :in_progress, skip_proofs: true)
    admin = create(:admin)
    proof_review = build(:proof_review,
                         application: application,
                         admin: admin,
                         proof_type: :income,
                         status: :rejected,
                         rejection_reason: nil)

    assert_not proof_review.valid?
    assert_includes proof_review.errors[:rejection_reason], "can't be blank"
  end

  def test_prevents_review_of_archived_application
    admin = create(:admin)
    application = create(:application, :archived)

    proof_review = build(:proof_review,
                         application: application,
                         admin: admin,
                         proof_type: :income,
                         status: :approved)

    assert_not proof_review.valid?
    assert_includes proof_review.errors[:application],
                    'cannot be reviewed when archived'
  end
end
