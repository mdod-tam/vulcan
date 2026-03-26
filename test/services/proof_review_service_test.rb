# frozen_string_literal: true

require 'test_helper'

class ProofReviewServiceTest < ActiveSupport::TestCase
  setup do
    @application = create(:application, :in_progress, skip_proofs: true)
    @admin = create(:admin)
  end

  test 'uses the reviewable proof type boundary from ProofReview' do
    assert_equal %w[income residency], ProofReview.reviewable_proof_types

    reviewer = Object.new
    reviewer.define_singleton_method(:review) do |**_kwargs|
      true
    end

    Applications::ProofReviewer.stub(:new, reviewer) do
      ProofReview.reviewable_proof_types.each do |proof_type|
        result = ProofReviewService.new(
          @application,
          @admin,
          { proof_type: proof_type, status: 'approved' }
        ).call

        assert result.success?, "#{proof_type} should be accepted by ProofReviewService"
      end
    end

    invalid_result = ProofReviewService.new(
      @application,
      @admin,
      { proof_type: 'medical_certification', status: 'approved' }
    ).call

    assert_not invalid_result.success?
    assert_equal 'Invalid proof type', invalid_result.message
  end

  test 'rejects income proof review when income_proof_required is false' do
    @application.update_columns(income_proof_required: false)

    result = ProofReviewService.new(
      @application,
      @admin,
      { proof_type: 'income', status: 'approved' }
    ).call

    assert_not result.success?
    assert_equal 'Income proof review is not applicable for this application', result.message
  end

  test 'allows residency proof review when income_proof_required is false' do
    @application.update_columns(income_proof_required: false)

    reviewer = Object.new
    reviewer.define_singleton_method(:review) { |**_kwargs| true }

    Applications::ProofReviewer.stub(:new, reviewer) do
      result = ProofReviewService.new(
        @application,
        @admin,
        { proof_type: 'residency', status: 'approved' }
      ).call

      assert result.success?, "Residency review should still work when income is off: #{result.message}"
    end
  end
end
