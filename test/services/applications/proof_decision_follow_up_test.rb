# frozen_string_literal: true

require 'test_helper'

module Applications
  # The effects of a recorded income, residency, or ID decision. The writers that record one schedule this after
  # their transaction commits; these tests run it directly on a decision the factory saved.
  class ProofDecisionFollowUpTest < ActiveSupport::TestCase
    include ProofResubmissionTestHelper

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
        proof_type: :income,
        proof_review: instance_of(ProofReview)
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
          params[:metadata] == { proof_type: 'income', proof_review_id: review.id } &&
          params[:deliver] == false
      end

      follow_up(review)
    end

    test 'an approval notification creation failure keeps the decision and records the incomplete follow-up' do
      review = create(:proof_review, application: @application, admin: @admin, proof_type: :income, status: :approved)
      Notification.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(Notification.new))

      assert_difference -> { Event.where(action: 'notification_creation_failed', auditable: @application).count }, 1 do
        follow_up(review)
      end

      assert review.reload.status_approved?
      assert_not Notification.exists?(notifiable: @application, action: 'proof_approved')
      event = Event.find_by!(action: 'notification_creation_failed', auditable: @application)
      assert_equal @admin.id, event.user_id
      assert_equal 'proof_approved', event.metadata['notification_type']
    end

    test 'the rejection-limit warning goes to its reviewer with truthful actor attribution' do
      ensure_system_audit_actor!
      @application.user.update!(communication_preference: :email, locale: 'en')
      @application.update!(total_rejections: ProofReview::MAX_REJECTIONS - 1, income_proof_status: :rejected)
      %w[email_header_text email_footer_text application_notifications_proof_rejected].each do |name|
        EmailTemplate.where(name: name, format: :text).destroy_all
        load Rails.root.join("db/seeds/email_templates/#{name}.rb")
      end
      ActionMailer::Base.deliveries.clear
      review = record_proof_review(application: @application, proof_type: :income, status: :rejected, admin: @admin, rejection_reason: 'Unreadable')

      assert_emails(1) { follow_up(review) }

      notification = Notification.find_by!(notifiable: @application, action: 'max_rejections_warning')
      assert_equal @admin.id, notification.recipient_id
      assert_equal @admin.id, notification.actor_id
      assert_nil notification.delivery_status
      assert_equal @admin.id, Event.find_by!(auditable: @application, action: 'max_rejections_warning').metadata['recipient_id']
      assert_equal ProofReview::MAX_REJECTIONS, @application.reload.total_rejections
      assert_not_predicate @application, :status_archived?
      assert SecureRequestForm.income_proof.active.exists?(application: @application)
      email = ActionMailer::Base.deliveries.sole
      assert_equal [@application.user.email], email.to
      body = email.body.decoded
      assert_includes body, I18n.t('application_notifications.proof_rejected.remaining_attempts_message', count: 1, locale: :en)
      assert_includes body, 'HOW TO SUBMIT A CORRECTED DOCUMENT:'
      assert_not_includes body, I18n.t('application_notifications.proof_rejected.archived_message', locale: :en)
    end

    test 'distinct rejection-limit decisions retain their audit while repeated follow-up is deduplicated' do
      freeze_time do
        @application.update!(total_rejections: ProofReview::MAX_REJECTIONS - 1)
        income = record_proof_review(application: @application, proof_type: :income, status: :rejected, admin: @admin, rejection_reason: 'Unreadable')
        follow_up(income)
        residency = record_proof_review(application: @application, proof_type: :residency, status: :rejected, admin: @admin, rejection_reason: 'Unreadable')

        assert_difference -> { Event.where(action: 'max_rejections_warning', auditable: @application).count }, 1 do
          follow_up(residency)
          follow_up(income)
        end
        assert_equal 2, Event.where(action: 'max_rejections_warning', auditable: @application).count
      end
    end

    test 'repeated follow-up keeps one archive intent and never redispatches its queued or failed notice' do
      @application.update!(total_rejections: ProofReview::MAX_REJECTIONS)
      review = record_proof_review(application: @application, proof_type: :income, status: :rejected, admin: @admin, rejection_reason: 'Unreadable')

      assert_difference -> { Notification.where(action: 'max_rejections_reached', notifiable: @application).count }, 1 do
        follow_up(review)
        follow_up(review)
      end
      notice = Notification.find_by!(action: 'max_rejections_reached', notifiable: @application)
      assert_equal 'queued', notice.delivery_status
      notice.mark_delivery_failed!(ArgumentError.new('invalid template'))

      assert_no_enqueued_jobs do
        follow_up(review)
      end
      assert_equal 'error', notice.reload.delivery_status
      assert_equal 1, Notification.where(action: 'max_rejections_reached', notifiable: @application).count
    end

    test 'archive intent creation failure reports the committed review with its existing follow-up warning' do
      @application.update!(total_rejections: ProofReview::MAX_REJECTIONS)
      original_create = Notification.method(:create!)
      fail_archive_intent = lambda do |**attributes|
        raise ActiveRecord::RecordInvalid, Notification.new if attributes[:action] == 'max_rejections_reached'

        original_create.call(**attributes)
      end
      result = nil

      Notification.stub(:create!, fail_archive_intent) do
        result = ProofReviewService.new(@application, @admin, ActionController::Parameters.new(
                                                                proof_decision_params(@application, 'income').merge(proof_type: 'income', status: 'rejected', rejection_reason: 'Unreadable')
                                                              )).call
      end

      assert result.success?, result.message
      assert result.data[:warning].present?
      assert_predicate @application.reload, :status_archived?
      assert_equal ProofReview::MAX_REJECTIONS + 1, @application.total_rejections
      assert Event.exists?(action: 'proof_review_follow_up_failed', auditable: @application)
      assert_not Notification.exists?(action: 'max_rejections_reached', notifiable: @application)
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
      first = record_proof_review(application: @application, proof_type: :income, status: :rejected, admin: @admin, rejection_reason: 'Unreadable')
      follow_up(first)

      assert_difference -> { ProofReview.count }, 1 do
        assert_difference -> { Event.where(action: 'proof_rejected', auditable: @application).count }, 1 do
          repeat = record_proof_review(application: @application, proof_type: :income, status: :rejected, admin: @admin, rejection_reason: 'Still unreadable')
          follow_up(repeat)
        end
      end
    end

    test 'a repeat approval follows up like a new one, so each approval has its own audit event and record' do
      first = record_proof_review(application: @application, proof_type: :income, status: :approved, admin: @admin)
      follow_up(first)

      assert_difference -> { ProofReview.count }, 1 do
        assert_difference -> { Event.where(action: 'proof_approved', auditable: @application).count }, 1 do
          assert_difference -> { Notification.where(action: 'proof_approved', notifiable: @application).count }, 1 do
            repeat = record_proof_review(application: @application, proof_type: :income, status: :approved, admin: @admin)
            follow_up(repeat)
          end
        end
      end
    end

    test 'approvals of two proofs in quick succession each keep their own audit event' do
      income = record_proof_review(application: @application, proof_type: :income, status: :approved, admin: @admin)
      residency = record_proof_review(application: @application, proof_type: :residency, status: :approved, admin: @admin)

      assert_difference -> { Event.where(action: 'proof_approved', auditable: @application).count }, 2 do
        follow_up(income)
        follow_up(residency)
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
