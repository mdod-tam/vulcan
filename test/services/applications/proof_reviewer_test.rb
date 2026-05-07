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

    test 'rejected review persists interpolated address-based rejection text' do
      @application.user.update!(
        physical_address_1: '123 Main St',
        physical_address_2: 'Apt 4B',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201'
      )
      create(
        :rejection_reason,
        code: 'address_mismatch_test',
        proof_type: 'income',
        locale: 'en',
        body: 'The address must match %{address}.'
      )

      @reviewer.review(
        proof_type: :income,
        status: :rejected,
        rejection_reason_code: 'address_mismatch_test',
        rejection_reason: 'Address mismatch'
      )

      review = @application.proof_reviews.find_by!(proof_type: :income, status: :rejected)
      assert_equal 'The address must match 123 Main St Apt 4B Baltimore MD 21201.', review.rejection_reason
    end

    test 'approved review triggers reconciler auto-approval audit' do
      app = create(:application, :in_progress, :income_not_required)
      app.update_columns(medical_certification_status: Application.medical_certification_statuses[:approved])
      app.update_columns(id_proof_status: Application.id_proof_statuses[:approved])
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

    test 're-rejection requests secure proof resubmission when not in paper context' do
      Current.paper_context = true
      @reviewer.review(
        proof_type: :income,
        status: :rejected,
        rejection_reason_code: 'missing_name',
        rejection_reason: 'First rejected reason text'
      )

      Current.paper_context = false
      travel AuditEventService::DEDUP_WINDOW + 1.second

      result = BaseService::Result.new(success: true, message: 'sent', data: {})
      service = mock('request-proof-resubmission')
      service.expects(:call).returns(result)
      Applications::RequestProofResubmission.expects(:new).with(
        application: @application,
        actor: @admin,
        proof_type: :income
      ).returns(service)

      assert_difference -> { Event.where(action: 'proof_rejected', auditable: @application).count }, 1 do
        assert_difference -> { @application.reload.total_rejections }, 1 do
          @reviewer.review(
            proof_type: :income,
            status: :rejected,
            rejection_reason_code: 'wrong_document',
            rejection_reason: 'Second rejected reason text'
          )
        end
      end
    end

    test 'review submission method comes from latest proof submission event metadata' do
      Current.paper_context = true
      Event.create!(
        auditable: @application,
        user: @application.user,
        action: 'income_proof_attached',
        metadata: { 'proof_type' => 'income', 'submission_method' => 'secure_form' }
      )
      @application.income_proof.attach(
        io: StringIO.new('test income proof'),
        filename: 'income-proof.pdf',
        content_type: 'application/pdf'
      )

      @reviewer.review(proof_type: :income, status: :approved)

      review = @application.proof_reviews.find_by!(proof_type: :income, status: :approved)
      assert_predicate review, :submission_method_secure_form?
    end

    test 'paper-origin review still requests secure proof resubmission outside paper intake context' do
      Current.paper_context = false
      Event.create!(
        auditable: @application,
        user: @application.user,
        action: 'income_proof_submitted',
        metadata: { 'proof_type' => 'income', 'submission_method' => 'paper' }
      )

      result = BaseService::Result.new(success: true, message: 'sent', data: {})
      service = mock('request-proof-resubmission')
      service.expects(:call).returns(result)
      Applications::RequestProofResubmission.expects(:new).with(
        application: @application,
        actor: @admin,
        proof_type: :income
      ).returns(service)

      @reviewer.review(
        proof_type: :income,
        status: :rejected,
        rejection_reason_code: 'missing_name',
        rejection_reason: 'Rejected after paper submission'
      )

      review = @application.proof_reviews.find_by!(proof_type: :income, status: :rejected)
      assert_predicate review, :submission_method_paper?
    end
  end
end
