# frozen_string_literal: true

require 'test_helper'

module Applications
  # The effects of a recorded income, residency, or ID decision. The writers that record one schedule this after
  # their transaction commits; these tests run it directly on a decision the factory saved.
  class ProofDecisionFollowUpTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @application = create(:application, :in_progress, skip_proofs: true)
      attach(@application.income_proof, 'income.pdf')
      attach(@application.residency_proof, 'residency.pdf')
    end

    teardown do
      Current.reset
    end

    test 'a rejection requests a secure proof resubmission instead of a legacy notification' do
      result = BaseService::Result.new(success: true, message: 'sent', data: {})
      service = mock('request-proof-resubmission')
      service.expects(:call).returns(result)
      RequestProofResubmission.expects(:new).with(
        application: @application,
        actor: @admin,
        proof_type: :income
      ).returns(service)
      NotificationService.expects(:create_and_deliver!).never

      assert_difference -> { Event.where(action: 'proof_rejected', auditable: @application).count }, 1 do
        follow_up(rejected_review(:income))
      end
    end

    test 'an approval is recorded for the managing guardian contact path' do
      guardian = create(:constituent, email: "guardian.proof.approval.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.proof.approval.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, :in_progress, user: dependent, managing_guardian: guardian, skip_proofs: true)
      attach(application.income_proof, 'income.pdf')
      review = create(:proof_review, application: application, admin: @admin, proof_type: :income, status: :approved)

      NotificationService.expects(:create_and_deliver!).with do |params|
        params[:type] == 'proof_approved' &&
          params[:recipient] == guardian &&
          params[:actor] == @admin &&
          params[:notifiable] == application &&
          params[:metadata] == { proof_type: 'income' } &&
          params[:deliver] == false
      end

      follow_up(review)
    end

    test 'a paper rejection requests a secure resubmission and queues the rejection letter' do
      @application.user.update!(communication_preference: :letter, phone_type: :voice)
      @application.update!(income_proof_status: :rejected)
      Current.paper_context = true
      review = rejected_review(:income, submission_method: :paper)

      assert_difference -> { SecureRequestForm.count }, 1 do
        assert_difference -> { PrintQueueItem.where(letter_type: :income_proof_rejected).count }, 1 do
          assert_difference -> { Event.where(action: 'proof_rejected', auditable: @application).count }, 1 do
            follow_up(review)
          end
        end
      end
      assert_not Notification.exists?(notifiable: @application, action: 'income_proof_rejected')
    end

    test 'a rejection queues the letter type of the rejected document' do
      @application.user.update!(communication_preference: :letter, phone_type: :voice)
      @application.update!(residency_proof_status: :rejected, id_proof_status: :rejected)
      Current.paper_context = true

      { residency: :residency_proof_rejected, id: :id_proof_rejected }.each do |proof_type, letter_type|
        review = rejected_review(proof_type, submission_method: :paper)

        assert_difference -> { PrintQueueItem.where(letter_type: letter_type).count }, 1, "#{proof_type} rejection queued the wrong letter" do
          follow_up(review)
        end
      end
    end

    test 'a repeat rejection of the same proof follows up like a new one, with its own audit event' do
      first = ProofReview.for_decision(@application, proof_type: :income, status: :rejected)
                         .record!(admin: @admin, rejection_reason: 'Unreadable')
      follow_up(first)

      assert_no_difference -> { ProofReview.count } do
        assert_difference -> { Event.where(action: 'proof_rejected', auditable: @application).count }, 1 do
          repeat = ProofReview.for_decision(@application, proof_type: :income, status: :rejected)
                              .record!(admin: @admin, rejection_reason: 'Still unreadable')
          follow_up(repeat)
        end
      end
    end

    test 'a repeat approval follows up like a new one, so each approval has its own audit event and record' do
      first = ProofReview.for_decision(@application, proof_type: :income, status: :approved).record!(admin: @admin)
      follow_up(first)

      travel AuditEventService::DEDUP_WINDOW + 1.second do
        assert_no_difference -> { ProofReview.count } do
          assert_difference -> { Event.where(action: 'proof_approved', auditable: @application).count }, 1 do
            assert_difference -> { Notification.where(action: 'proof_approved', notifiable: @application).count }, 1 do
              repeat = ProofReview.for_decision(@application, proof_type: :income, status: :approved).record!(admin: @admin)
              follow_up(repeat)
            end
          end
        end
      end
    end

    test 'a disability certification review is refused, because its follow-up belongs to the certification flow' do
      certification_review = create(:proof_review, application: @application, admin: @admin,
                                                   proof_type: :disability_certification, status: :rejected,
                                                   rejection_reason: 'Missing signature')

      error = assert_raises(ArgumentError) { ProofDecisionFollowUp.new(certification_review) }

      assert_includes error.message, 'disability_certification'
      assert_no_difference -> { Event.where(action: 'proof_rejected', auditable: @application).count } do
        assert_raises(ArgumentError) { ProofDecisionFollowUp.new(certification_review).call }
      end
    end

    test 'a decision whose application has no applicant is left alone' do
      review = rejected_review(:income)
      review.application.stubs(:user).returns(nil)

      assert_no_difference -> { Event.where(action: 'proof_rejected').count } do
        follow_up(review)
      end
    end

    private

    def follow_up(review)
      ProofDecisionFollowUp.new(review).call
    end

    def rejected_review(proof_type, submission_method: nil)
      create(:proof_review, application: @application, admin: @admin, proof_type: proof_type, status: :rejected,
                            rejection_reason: 'Invalid documentation', submission_method: submission_method)
    end

    def attach(attachment, filename)
      attachment.attach(io: StringIO.new("#{filename} content"), filename: filename, content_type: 'application/pdf')
    end
  end
end
