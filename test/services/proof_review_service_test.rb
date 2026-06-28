# frozen_string_literal: true

require 'test_helper'

class ProofReviewServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @application = create(:application, :in_progress, skip_proofs: true)
    @admin = create(:admin)
    @application.income_proof.attach(
      io: StringIO.new('income proof'),
      filename: 'income-proof.pdf',
      content_type: 'application/pdf'
    )
    @application.residency_proof.attach(
      io: StringIO.new('residency proof'),
      filename: 'residency-proof.pdf',
      content_type: 'application/pdf'
    )
    @application.id_proof.attach(
      io: StringIO.new('id proof'),
      filename: 'id-proof.pdf',
      content_type: 'application/pdf'
    )
  end

  test 'uses the reviewable proof type boundary from ProofReview' do
    assert_equal %w[income id residency], ProofReview.reviewable_proof_types

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

  test 'returns rejected proof review and resubmission delivery status' do
    proof_review = build_stubbed(:proof_review,
                                 application: @application,
                                 admin: @admin,
                                 proof_type: 'income',
                                 status: 'rejected',
                                 rejection_reason: 'Income documentation is not acceptable.')
    reviewer = mock('proof_reviewer')
    reviewer.stubs(:review).returns(true)
    reviewer.stubs(:proof_review).returns(proof_review)
    Applications::ProofReviewer.stubs(:new).returns(reviewer)
    Applications::RequestProofResubmission.stubs(:delivery_confirmed_for_review?)
                                          .with(proof_review)
                                          .returns(false)

    result = ProofReviewService.new(
      @application,
      @admin,
      {
        proof_type: 'income',
        status: 'rejected',
        rejection_reason: 'Income documentation is not acceptable.'
      }
    ).call

    assert result.success?, result.message
    assert_equal proof_review, result.data[:proof_review]
    assert_equal false, result.data[:resubmission_delivered]
  end

  test 'rejects proof review when the proof is not currently reviewable' do
    @application.update_columns(income_proof_status: Application.income_proof_statuses[:approved])

    result = ProofReviewService.new(
      @application,
      @admin,
      { proof_type: 'income', status: 'approved' }
    ).call

    assert_not result.success?
    assert_equal 'Proof is not reviewable for this application', result.message
  end

  test 'rejecting one proof is not blocked by unrelated missing required proofs' do
    application = create(:application, :in_progress)
    application.residency_proof.attach(
      io: StringIO.new('residency proof'),
      filename: 'residency-proof.pdf',
      content_type: 'application/pdf'
    )
    NotificationService.stubs(:create_and_deliver!).returns(true)

    with_required_proof_validations do
      result = ProofReviewService.new(
        application,
        @admin,
        {
          proof_type: 'residency',
          status: 'rejected',
          rejection_reason: 'Address mismatch'
        }
      ).call

      assert result.success?, result.message
    end

    assert_equal 'rejected', application.reload.residency_proof_status
    assert_not application.income_proof.attached?
    assert_not Current.reviewing_single_proof?
  end

  test 'rejecting income then residency and id succeeds after previous rejected proof attachments are purged' do
    NotificationService.stubs(:create_and_deliver!).returns(true)

    with_required_proof_validations do
      assert_difference -> { @application.reload.total_rejections }, 3 do
        perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
          income_result = ProofReviewService.new(
            @application,
            @admin,
            {
              proof_type: 'income',
              status: 'rejected',
              rejection_reason: 'Income documentation is not acceptable.'
            }
          ).call
          assert income_result.success?, income_result.message
        end
        assert_not @application.reload.income_proof.attached?

        perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
          residency_result = ProofReviewService.new(
            @application,
            @admin,
            {
              proof_type: 'residency',
              status: 'rejected',
              rejection_reason: 'Residency documentation is not acceptable.'
            }
          ).call
          assert residency_result.success?, residency_result.message
        end
        assert_not @application.reload.residency_proof.attached?

        perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
          id_result = ProofReviewService.new(
            @application,
            @admin,
            {
              proof_type: 'id',
              status: 'rejected',
              rejection_reason: 'ID documentation is not acceptable.'
            }
          ).call
          assert id_result.success?, id_result.message
        end
        assert_not @application.reload.id_proof.attached?
      end
    end

    assert_equal 'rejected', @application.income_proof_status
    assert_equal 'rejected', @application.residency_proof_status
    assert_equal 'rejected', @application.id_proof_status
    assert_not Current.reviewing_single_proof?
  end

  private

  def with_required_proof_validations
    previous_value = ENV.fetch('REQUIRE_PROOF_VALIDATIONS', nil)
    ENV['REQUIRE_PROOF_VALIDATIONS'] = 'true'
    Current.reset

    yield
  ensure
    if previous_value.nil?
      ENV.delete('REQUIRE_PROOF_VALIDATIONS')
    else
      ENV['REQUIRE_PROOF_VALIDATIONS'] = previous_value
    end
    Current.reset
  end
end
