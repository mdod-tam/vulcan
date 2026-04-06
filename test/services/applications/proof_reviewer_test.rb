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
      Current.user = nil
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

    test 'approved review triggers reconciler auto-approval audit' do
      app = create(:application, :in_progress, :income_not_required)
      app.update_columns(medical_certification_status: Application.medical_certification_statuses[:approved])
      app.residency_proof.attach(
        io: StringIO.new('test residency proof'),
        filename: 'residency-proof.pdf',
        content_type: 'application/pdf'
      )
      app.stubs(:purge_rejected_proof).returns(true)
      Current.user = @admin

      reviewer = ProofReviewer.new(app, @admin)

      assert_difference -> { app.status_changes.count }, 1 do
        assert_difference -> { Event.where(action: 'application_status_changed', auditable: app).count }, 1 do
          assert_no_difference -> { Event.where(action: 'application_auto_approved', auditable: app).count } do
            reviewer.review(proof_type: :residency, status: :approved)
          end
        end
      end

      app.reload
      assert app.status_approved?

      status_change = app.status_changes.order(:created_at).last
      assert_equal @admin, status_change.user
      assert_equal 'auto_approval', status_change.metadata['trigger']

      status_event = Event.where(action: 'application_status_changed', auditable: app).order(:created_at).last
      assert_equal 'auto_approval', status_event.metadata['trigger']
      assert_equal 'approved', status_event.metadata['new_status']
    end
  end
end
