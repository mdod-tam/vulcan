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

  test 'a failure before saving the review leaves no review or side effects' do
    ProofReview.any_instance.stubs(:save!).raises(StandardError, 'review save failed')

    result = nil
    assert_no_difference ['ProofReview.count', 'ApplicationStatusChange.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = review_income
      end
    end

    assert result.failure?
    assert_includes result.message, 'review save failed'
    assert_equal 'not_reviewed', @application.reload.income_proof_status
    assert_equal 'in_progress', @application.status
    assert_not Current.reviewing_single_proof?
  end

  test 'reconciliation failure rolls back the proof review and proof status' do
    @application.stubs(:reconcile_workflow_state!).raises(StandardError, 'reconciliation failed')

    result = nil
    assert_no_difference ['ProofReview.count', 'ApplicationStatusChange.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        result = review_income
      end
    end

    assert result.failure?
    assert_includes result.message, 'reconciliation failed'
    assert_equal 'not_reviewed', @application.reload.income_proof_status
    assert_equal 'in_progress', @application.status
    assert_not Current.reviewing_single_proof?
  end

  test 'a delivery confirmation query failure does not report the saved rejection as failed' do
    Applications::RequestProofResubmission.stubs(:delivery_confirmed_for_review?).raises(ActiveRecord::ConnectionNotEstablished)

    result = ProofReviewService.new(@application, @admin,
                                    { proof_type: 'income', status: 'rejected', rejection_reason: 'Missing name' }).call

    assert result.success?, result.message
    assert_match(/review was saved.*delivery could not be confirmed/, result.data[:warning])
    assert_equal 'rejected', @application.reload.income_proof_status
    review = @application.proof_reviews.where(proof_type: :income, status: :rejected).sole
    assert_equal review, result.data[:proof_review]
    assert_not result.data.key?(:resubmission_delivered)
  end

  test 'lifecycle audit failure rolls back its status and history with the proof review' do
    @application.update!(residency_proof_status: :approved, id_proof_status: :approved,
                         medical_certification_status: :approved)
    original_log = AuditEventService.method(:log)
    audit_failure = lambda do |**attributes|
      next original_log.call(**attributes) unless attributes[:action] == 'application_status_changed'

      assert_equal 'approved', Application.find(@application.id).status
      assert @application.status_changes.exists?(from_status: 'in_progress', to_status: 'approved', user: @admin)
      raise 'lifecycle audit failed'
    end

    result = nil
    assert_no_difference ['ProofReview.count', 'ApplicationStatusChange.count', 'Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs do
        AuditEventService.stub :log, audit_failure do
          result = review_income
        end
      end
    end

    assert result.failure?
    assert_includes result.message, 'lifecycle audit failed'
    assert_equal 'not_reviewed', @application.reload.income_proof_status
    assert_equal 'in_progress', @application.status
    assert_not Current.reviewing_single_proof?
  end

  test 'uses the reviewable proof type boundary from ProofReview' do
    assert_equal %w[income id residency], ProofReview.reviewable_proof_types

    ProofReview.reviewable_proof_types.each do |proof_type|
      result = ProofReviewService.new(
        @application,
        @admin,
        { proof_type: proof_type, status: 'approved' }
      ).call

      assert result.success?, "#{proof_type} should be accepted by ProofReviewService: #{result.message}"
      review = @application.proof_reviews.find_by!(proof_type: proof_type, status: :approved)
      assert_equal review, result.data[:proof_review]
      assert_equal @admin, review.admin
      assert_equal 'approved', @application.reload.public_send("#{proof_type}_proof_status")
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

    result = ProofReviewService.new(
      @application,
      @admin,
      { proof_type: 'residency', status: 'approved' }
    ).call

    assert result.success?, "Residency review should still work when income is off: #{result.message}"
    assert_equal 'approved', @application.reload.residency_proof_status
    assert_equal @application.proof_reviews.find_by!(proof_type: :residency, status: :approved), result.data[:proof_review]
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
    reviewer.stubs(:warning).returns(nil)
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

  test 'a rejection whose resubmission email is turned off reports suppression, not a delivery failure' do
    EmailDelivery::ControlWriter.set(name: EmailDelivery.category_control('proof'), enabled: false, actor: @admin,
                                     operation_id: 'op-1')

    result = ProofReviewService.new(
      @application,
      @admin,
      { proof_type: 'residency', status: 'rejected', rejection_reason: 'Address mismatch' }
    ).call

    assert result.success?, result.message
    assert_equal 'rejected', @application.reload.residency_proof_status
    assert_equal false, result.data[:resubmission_delivered]
    assert result.data[:resubmission_suppressed]
    event = Event.find_by!(action: 'proof_resubmission_request_failed', auditable: @application)
    assert event.metadata['delivery_suppressed']
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

  def review_income
    ProofReviewService.new(@application, @admin, { proof_type: 'income', status: 'approved' }).call
  end

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

# These outcomes require the transaction to commit, including its callbacks.
class ProofReviewCommitOutcomeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ConcurrencyTestHelper

  self.use_transactional_tests = false

  setup do
    @admin = create(:admin)
    @user = create(:constituent)
    @application = create(:application, :in_progress, :income_not_required, user: @user)
    @application.residency_proof.attach(io: StringIO.new('residency proof'), filename: 'residency.pdf', content_type: 'application/pdf')
    @application.id_proof.attach(io: StringIO.new('ID proof'), filename: 'id.pdf', content_type: 'application/pdf')
    @application.update!(id_proof_status: :approved, medical_certification_status: :approved)
    clear_enqueued_jobs
  end

  teardown do
    cleanup_duplicate_review_test_data!(@user, @admin)
    Current.reset
    clear_enqueued_jobs
  end

  test 'a committed callback failure preserves review lifecycle history and audit with a warning' do
    ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit failed')

    result = review_residency

    assert result.success?, result.message
    assert_match(/review was saved.*follow-up step/, result.data[:warning])
    review = ProofReview.find(result.data[:proof_review].id)
    assert_equal 'approved', review.status
    assert_equal @admin, review.admin
    assert_equal 'approved', @application.reload.residency_proof_status
    assert_equal 'approved', @application.status
    history = @application.status_changes.where(from_status: 'in_progress', to_status: 'approved').sole
    assert_equal @admin, history.user
    assert @application.events.exists?(action: 'application_status_changed')
    failure = @application.events.where(action: 'proof_review_follow_up_failed').sole
    assert_equal review.id, failure.metadata['proof_review_id']
    assert_equal 'StandardError', failure.metadata['error_class']
    assert_not Current.reviewing_single_proof?
  end

  test 'failed commit verification reports uncertainty without suggesting the review failed' do
    ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit failed')
    ProofReview.stubs(:find_by).raises(ActiveRecord::ConnectionNotEstablished, 'verification unavailable')

    result = review_residency

    assert result.failure?
    assert_equal :unknown, result.data[:commit_state]
    assert_match(/may have been saved.*could not be confirmed/, result.message)
    assert_match(/before reviewing it again/, result.message)
    assert_not_includes result.message, 'Proof review failed'
    assert_equal 'approved', @application.reload.residency_proof_status
    assert_equal 'approved', @application.status
    assert_equal 1, @application.proof_reviews.where(proof_type: :residency, status: :approved).count
    assert @application.status_changes.exists?(to_status: 'approved')
    assert @application.events.exists?(action: 'application_status_changed')
    assert_not @application.events.exists?(action: 'proof_review_follow_up_failed')
  end

  test 'a repeated rejection keeps its committed review and reports a follow-up failure' do
    ProofReview.any_instance.stubs(:handle_post_review_actions).returns(true)
    review = create(:proof_review, application: @application, admin: @admin, proof_type: :residency,
                                   status: :rejected, rejection_reason: 'Old reason', reviewed_at: 1.day.ago)
    ProofReview.any_instance.stubs(:apply_repeat_rejection_side_effects!).raises(StandardError, 'repeat follow-up failed')

    result = ProofReviewService.new(@application, @admin,
                                    { proof_type: 'residency', status: 'rejected', rejection_reason: 'New reason' }).call

    assert result.success?, result.message
    assert_match(/review was saved.*follow-up step/, result.data[:warning])
    assert_equal review.id, result.data[:proof_review].id
    assert_equal 'New reason', review.reload.rejection_reason
    assert_equal 'rejected', @application.reload.residency_proof_status
    assert_equal 'in_progress', @application.status
    failure = @application.events.where(action: 'proof_review_follow_up_failed').sole
    assert_equal review.id, failure.metadata['proof_review_id']
  end

  test 'an unchanged repeated review under frozen time cannot prove a failed transaction committed' do
    freeze_time do
      assert review_residency.success?
      review = @application.proof_reviews.where(proof_type: :residency, status: :approved).sole
      original_attributes = review.attributes_for_database
      original_transaction = ApplicationRecord.method(:transaction)
      transaction_open = false
      fail_before_commit = lambda do |**options, &block|
        next original_transaction.call(**options, &block) if transaction_open

        transaction_open = true
        begin
          original_transaction.call(**options) do
            block.call
            raise 'transaction did not commit'
          end
        ensure
          transaction_open = false
        end
      end

      reviewer = Applications::ProofReviewer.new(@application, @admin)
      ApplicationRecord.stub :transaction, fail_before_commit do
        assert_raises Applications::ProofReviewer::CommitUnconfirmed do
          reviewer.review(proof_type: :residency, status: :approved)
        end
      end

      assert_equal original_attributes, review.reload.attributes_for_database
      assert_nil reviewer.warning
      assert_not @application.events.exists?(action: 'proof_review_follow_up_failed')
    end
  end

  private

  def review_residency
    ProofReviewService.new(@application, @admin, { proof_type: 'residency', status: 'approved' }).call
  end
end
