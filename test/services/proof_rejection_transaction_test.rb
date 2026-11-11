# frozen_string_literal: true

require 'test_helper'

class ProofRejectionTransactionTest < ActiveSupport::TestCase
  include ProofResubmissionTestHelper
  include ConcurrencyTestHelper

  self.use_transactional_tests = false

  setup do
    @admin = create(:admin)
    @user = create(:constituent)
    @application = create(:application, :in_progress, user: @user, submission_method: :paper, skip_proofs: true)
    @params = proof_decision_params(@application, :income).merge(
      application: @application, admin: @admin, proof_type: :income, submission_method: :paper, reason: 'Missing proof'
    )
  end

  teardown do
    ProofReview.skip_callback(:commit, :after, @commit_failure) if @commit_failure
    @application.proof_reviews.unstub(:find_by)
    cleanup_duplicate_review_test_data!(@admin, @user)
    Current.reset
  end

  test 'a paper rejection failure before insert rolls back its state and count' do
    ProofReview.any_instance.stubs(:save!).raises(StandardError, 'save failed')

    result = ProofAttachmentService.reject_proof_without_attachment(**@params)

    assert_not result[:success]
    assert_equal 0, @application.proof_reviews.count
    assert_equal 0, @application.reload.total_rejections
    assert_equal 'not_reviewed', @application.income_proof_status
    assert_not Event.exists?(auditable: @application, action: 'proof_rejected')
  end

  test 'a committed paper rejection reports its callback failure and its replay performs no follow-up' do
    Applications::ProofDecisionFollowUp.any_instance.stubs(:call).raises(StandardError, 'follow-up failed')

    first = ProofAttachmentService.reject_proof_without_attachment(**@params)

    assert first[:success], first[:error]&.message
    assert_match(/saved.*follow-up step/, first[:warning])
    assert_equal 1, @application.reload.total_rejections
    assert_equal 'rejected', @application.income_proof_status
    assert_equal first[:proof_review].id, @application.proof_reviews.sole.id

    assert_no_difference ['ProofReview.count', 'Event.count', 'Notification.count', 'SecureRequestForm.count',
                          '@application.reload.total_rejections'] do
      replay = ProofAttachmentService.reject_proof_without_attachment(**@params)
      assert replay[:success], replay[:error]&.message
      assert_equal first[:proof_review].id, replay[:proof_review].id
    end
  end

  test 'an unreadable paper commit reports unknown without claiming the saved rejection was lost' do
    application = @application
    @commit_failure = lambda do |_review|
      application.proof_reviews.stubs(:find_by).raises(ActiveRecord::ConnectionNotEstablished)
      raise StandardError, 'commit callback failed'
    end
    ProofReview.after_commit(@commit_failure, on: :create)

    result = ProofAttachmentService.reject_proof_without_attachment(**@params)

    assert_not result[:success]
    assert_equal :unknown, result[:commit_state]
    assert_kind_of Applications::ReviewCommit::Unconfirmed, result[:error]
    assert_match(/may have been saved.*could not be confirmed/, result[:error].message)
    assert_equal 1, ProofReview.where(application_id: @application.id).count
    assert_equal 1, @application.reload.total_rejections
    assert_equal 'rejected', @application.income_proof_status
  end

  test 'a committed certification approval reports a callback failure as a saved decision' do
    params = certification_approval_params
    @commit_failure = ->(_review) { raise StandardError, 'approval callback failed' }
    ProofReview.after_commit(@commit_failure, on: :create)

    result = DisabilityCertificationAttachmentService.update_certification_status(**params)

    assert result[:success], result[:error]&.message
    assert_match(/approval was saved.*follow-up step/, result[:warning])
    assert_equal 1, @application.proof_reviews.count
    assert @application.reload.disability_certification_status_approved?
  end

  test 'an unreadable certification approval reports unknown while preserving its decision' do
    params = certification_approval_params
    application = @application
    @commit_failure = lambda do |_review|
      application.proof_reviews.stubs(:find_by).raises(ActiveRecord::ConnectionNotEstablished)
      raise StandardError, 'approval callback failed'
    end
    ProofReview.after_commit(@commit_failure, on: :create)

    result = DisabilityCertificationAttachmentService.update_certification_status(**params)

    assert_not result[:success]
    assert_equal :unknown, result[:commit_state]
    assert_kind_of Applications::ReviewCommit::Unconfirmed, result[:error]
    assert_equal 1, ProofReview.where(application_id: @application.id).count
    assert @application.reload.disability_certification_status_approved?
  end

  test 'the paper caller owns its outer rollback and no follow-up escapes it' do
    Applications::ProofDecisionFollowUp.expects(:new).never

    ApplicationRecord.transaction do
      result = ProofAttachmentService.reject_proof_without_attachment(**@params)
      assert result[:success], result[:error]&.message
      raise ActiveRecord::Rollback
    end

    assert_equal 0, ProofReview.where(application_id: @application.id).count
    assert_equal 0, @application.reload.total_rejections
    assert_equal 'not_reviewed', @application.income_proof_status
    assert_not Event.exists?(auditable: @application, action: 'proof_rejected')
  end

  private

  def certification_approval_params
    @application.disability_certification.attach(io: file_fixture('disability_certification_valid.pdf').open,
                                                 filename: 'certification.pdf', content_type: 'application/pdf')
    mark_document_clean!(@application.disability_certification.blob, user: @admin, purpose: :certification, slot: 'disability_certification')
    proof_decision_params(@application, :disability_certification).merge(application: @application, admin: @admin, status: :approved)
  end
end
