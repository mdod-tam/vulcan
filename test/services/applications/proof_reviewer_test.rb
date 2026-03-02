# frozen_string_literal: true

require 'test_helper'

module Applications
  class ProofReviewerTest < ActiveSupport::TestCase
    setup do
      @application = create(:application, :in_progress)
      @admin = create(:admin)
      @reviewer = ProofReviewer.new(@application, @admin)

      Current.paper_context = true
      @application.stubs(:purge_rejected_proof).returns(true)
    end

    teardown do
      Current.paper_context = nil
    end

    test 'rejected re-review updates existing proof review when reason code changes' do
      assert_difference -> { @application.proof_reviews.where(proof_type: :income, status: :rejected).count }, +1 do
        @reviewer.review(
          proof_type: :income,
          status: :rejected,
          rejection_reason_code: 'missing_name',
          rejection_reason: 'First rejected reason text'
        )
      end

      original_review_id = @application.proof_reviews.find_by!(proof_type: :income, status: :rejected).id

      assert_no_difference -> { @application.proof_reviews.where(proof_type: :income, status: :rejected).count } do
        @reviewer.review(
          proof_type: :income,
          status: :rejected,
          rejection_reason_code: 'wrong_document',
          rejection_reason: 'Second rejected reason text'
        )
      end

      review = @application.proof_reviews.find_by!(proof_type: :income, status: :rejected)
      assert_equal original_review_id, review.id
      assert_equal 'wrong_document', review.rejection_reason_code
      assert review.rejection_reason.present?
    end

    test 'non-rejected reviews do not persist rejection reason code' do
      @application.income_proof.attach(
        io: StringIO.new('test income proof'),
        filename: 'income-proof.pdf',
        content_type: 'application/pdf'
      )

      @reviewer.review(
        proof_type: :income,
        status: :approved,
        rejection_reason_code: 'wrong_document',
        rejection_reason: 'Should not persist for approved review'
      )

      review = @application.proof_reviews.find_by!(proof_type: :income, status: :approved)
      assert_nil review.rejection_reason_code
      assert_nil review.rejection_reason
    end
  end
end
