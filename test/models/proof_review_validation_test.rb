# frozen_string_literal: true

require 'test_helper'

class ProofReviewValidationTest < ActiveSupport::TestCase
  def setup
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

  test 'an administrator can create a proof review' do
    admin = create(:admin)

    proof_review = ProofReview.new(
      application: @application,
      admin: admin,
      proof_type: 'income',
      status: 'approved'
    )

    assert proof_review.valid?, "Proof review should be valid with administrator #{admin.type}"
  end

  test 'non-admin user cannot create a proof review' do
    user = create(:constituent)

    proof_review = ProofReview.new(
      application: @application,
      admin: user,
      proof_type: 'income',
      status: 'approved'
    )

    assert_not proof_review.valid?, 'Proof review should not be valid with non-admin user'
    assert_includes proof_review.errors[:admin], 'must be an administrator'
  end
end
