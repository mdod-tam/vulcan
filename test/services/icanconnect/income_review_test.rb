# frozen_string_literal: true

require 'test_helper'

module Icanconnect
  class IncomeReviewTest < ActiveSupport::TestCase
    include IcanconnectTestSupport
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      ensure_system_audit_actor!
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @verified_on = Date.new(2025, 5, 1)
      @mail_delivery = mock('income-proof-delivery')
      @mail_delivery.stubs(:deliver_now).returns(true)
      @mail_delivery.stubs(:deliver_later).returns(true)
      ApplicationNotificationsMailer.stubs(:proof_requested).returns(@mail_delivery)
      ApplicationNotificationsMailer.stubs(:proof_rejected).returns(@mail_delivery)
      ApplicationNotificationsMailer.stubs(:proof_received).returns(@mail_delivery)
    end

    teardown do
      Current.reset
    end

    test 'ordinary approval permits initial ICC funding and later ICC work needs updated income proof at one year' do
      application = nil
      travel_to @verified_on.in_time_zone.noon do
        application = approved_deafblind_application
        assert application.status_approved?
        assert_equal @verified_on, application.income_last_verified_at.to_date
        assert_equal 1, application.proof_reviews.proof_type_income.status_approved.count
        assert_nothing_raised { Funding.validate!(application, source: 'icanconnect') }
        icc_order_with_unit(application: application)
      end

      anniversary = @verified_on.next_year
      travel_to anniversary.in_time_zone.noon do
        assert_not application.icanconnect_income_review_due?(on: anniversary.prev_day)
        assert application.icanconnect_income_review_due?(on: anniversary)
        assert application.proof_requestable_via_secure_form?(:income)
        assert_nothing_raised { Funding.validate!(application, source: 'mat') }
        assert_nothing_raised { Funding.validate!(application, source: 'icanconnect', on: anniversary.prev_day) }
        assert_raises(Funding::Ineligible) { Funding.validate!(application, source: 'icanconnect') }
      end
    end

    test 'MAT delivery and undelivered ICC equipment do not trigger an annual income update' do
      application = supplied_application
      application.equipment_items.sole.update!(delivered_on: nil)
      create(:equipment_item, application: application, delivered_on: @verified_on, shipped_at: @verified_on, tracking_number: 'MAT-DELIVERY', funding_source: 'mat',
                              purchase_order: create(:purchase_order, sent_at: @verified_on))

      travel_to @verified_on.next_year.in_time_zone.noon do
        assert_not application.icanconnect_income_review_due?
        assert_not application.income_proof_update_available?
        assert_nothing_raised { Funding.validate!(application, source: 'icanconnect') }
      end
    end

    { constituent: false, guardian: true }.each do |audience, managed|
      test "annual income proof uses the ordinary secure request for the #{audience} and returns to normal proof review" do
        guardian = create(:constituent) if managed
        user = create(:constituent, hearing_disability: true, vision_disability: true)
        create(:guardian_relationship, guardian_user: guardian, dependent_user: user, relationship_type: 'Parent') if managed
        application = supplied_application(user: user, managing_guardian: guardian)
        recipient = guardian || user
        lifecycle = application.status_changes.order(:id).ids
        previous_proof = application.income_proof.blob

        travel_to @verified_on.next_year.in_time_zone.noon do
          request = Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :income).call
          assert request.success?, request.message
          form = request.data.fetch(:secure_request_forms).sole
          assert_equal recipient.id, form.recipient_id
          assert_equal audience.to_s, form.recipient_role
          assert_equal recipient.email, form.recipient_email
          assert_equal recipient.id, form.delivery_owner_id
          notice = Notification.find_by!(recipient: @admin, notifiable: application, action: 'income_proof_update_requested')
          assert_equal form.id, notice.metadata.fetch('secure_request_form_id')
          assert_equal form.request_batch_id, notice.metadata.fetch('request_batch_id')
          assert application.reload.status_approved?
          assert_equal lifecycle, application.status_changes.order(:id).ids

          replacement = scanned_upload(fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf'),
                                       secure_form: form, slot: 'income_proof')
          submission = Applications::SubmitProofResubmission.new(application: application, secure_request_form: form, file: replacement.signed_id).call
          assert submission.success?, submission.message
          assert form.reload.submitted?
          assert_equal replacement.id, application.reload.income_proof.blob.id
          assert application.income_proof_status_not_reviewed?
          assert_not application.income_proof_update_available?
          assert_not application.proof_requestable_via_secure_form?(:income)
          assert_no_difference ['SecureRequestForm.count', 'Notification.count'] do
            retry_request = Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :income).call
            assert retry_request.failure?
          end
          assert application.status_approved?
          assert_equal lifecycle, application.status_changes.order(:id).ids
          assert Application.awaiting_proof_review.exists?(application.id)
          assert Application.staff_review_queue.exists?(application.id)
          assert Notification.exists?(recipient: @admin, notifiable: application, action: 'income_proof_update_received')
          assert_includes application.previous_income_proofs.blobs.ids, previous_proof.id
          assert AttachmentAccess.new(previous_proof).allowed?(@admin)
          assert_not AttachmentAccess.new(previous_proof).allowed?(recipient)
          assert_not AttachmentAccess.new(previous_proof).public?
          retained = application.previous_income_proofs.attachments.find_by!(blob_id: previous_proof.id)
          assert_raises(ActiveRecord::RecordNotDestroyed) { retained.purge }
          ActiveStorage::PurgeJob.perform_now(previous_proof)
          assert previous_proof.reload.service.exist?(previous_proof.key)
          assert_nothing_raised { Funding.validate!(application, source: 'mat') }
          assert_nothing_raised { Funding.validate!(application, source: 'icanconnect', on: Date.current.prev_day) }
          assert_raises(Funding::Ineligible) { Funding.validate!(application, source: 'icanconnect') }

          Applications::ProofReviewer.new(application, @admin).review(proof_type: :income, status: :approved, decision_key: SecureRandom.uuid,
                                                                      reviewed_blob_id: application.income_proof.blob.id)
          assert_equal Date.current, application.reload.income_last_verified_at.to_date
          assert application.status_approved?
          assert_equal lifecycle, application.status_changes.order(:id).ids
          assert_not Application.awaiting_proof_review.exists?(application.id)
          assert_not application.icanconnect_income_review_due?
          assert_nothing_raised { Funding.validate!(application, source: 'icanconnect') }
        end
      end
    end

    test 'multiple recipient forms create one admin notice per income request batch' do
      guardian = create(:constituent)
      user = create(:constituent, hearing_disability: true, vision_disability: true)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: user, relationship_type: 'Parent')
      application = supplied_application(user: user, managing_guardian: guardian)
      notices = Notification.where(recipient: @admin, notifiable: application, action: 'income_proof_update_requested')
      batches = []

      travel_to @verified_on.next_year.in_time_zone.noon do
        2.times do |index|
          travel 61.minutes if index.positive?
          request = nil
          assert_difference -> { notices.count }, 1 do
            request = Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :income,
                                                                 recipient_ids: [user.id, guardian.id]).call
            assert request.success?, request.message
          end
          forms = request.data.fetch(:secure_request_forms)
          assert_equal [user.id, guardian.id].sort, forms.map(&:recipient_id).sort
          batch = forms.map(&:request_batch_id).uniq.sole
          batches << batch
          notice = notices.where("metadata->>'request_batch_id' = ?", batch).sole
          assert_includes forms.map(&:id), notice.metadata.fetch('secure_request_form_id')
        end
      end
      assert_equal 2, batches.uniq.size
      assert_equal batches.sort, notices.map { |notice| notice.metadata.fetch('request_batch_id') }.sort
    end

    test 'rejecting a later income update preserves MAT approval and does not recount the initial rejection total on retry' do
      application = supplied_application
      application.update!(total_rejections: ProofReview::MAX_REJECTIONS)
      lifecycle = application.status_changes.order(:id).ids

      travel_to @verified_on.next_year.in_time_zone.noon do
        replacement = scanned_upload(fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf'),
                                     user: @admin, slot: 'income_proof')
        result = ProofAttachmentService.attach_proof(application: application, proof_type: :income, blob_or_file: replacement.signed_id,
                                                     scan_owner: @admin, admin: @admin, submission_method: :web)
        assert result[:success], result[:error]&.message
        decision = { proof_type: :income, status: :rejected, decision_key: SecureRandom.uuid,
                     reviewed_blob_id: replacement.id, rejection_reason: 'The income document is unreadable.' }
        reviewer = Applications::ProofReviewer.new(application, @admin)
        reviewer.review(**decision)
        assert_nil reviewer.proof_review.rejection_total
        assert_equal ProofReview::MAX_REJECTIONS, application.reload.total_rejections
        assert application.status_approved?
        assert application.income_proof_status_rejected?
        assert_equal lifecycle, application.status_changes.order(:id).ids
        assert_nothing_raised { Funding.validate!(application, source: 'mat') }
        assert_raises(Funding::Ineligible) { Funding.validate!(application, source: 'icanconnect') }
        assert_no_difference ['ProofReview.count', 'ApplicationStatusChange.count'] do
          Applications::ProofReviewer.new(application, @admin).review(**decision)
        end
        assert_equal ProofReview::MAX_REJECTIONS, application.reload.total_rejections
      end
    end

    test 'a later income approval does not approve ICC services during an earlier rejected interval' do
      application = supplied_application(application_date: @verified_on)
      lifecycle = application.status_changes.order(:id).ids
      rejected_on = @verified_on + 2.months
      approved_on = rejected_on + 1.month
      trainer = create(:trainer)
      session = nil
      initial_service_on = @verified_on + 1.month
      travel_to initial_service_on.in_time_zone.noon do
        application.update!(assigned_trainer: trainer)
        session = create(:training_session, :scheduled, application: application, trainer: trainer, scheduled_for: 2.weeks.from_now,
                                                        funding_source: 'icanconnect', funding_service_on: Date.current)
      end

      { rejected_on => :rejected, approved_on => :approved }.each do |date, status|
        travel_to date.in_time_zone.noon do
          replacement = scanned_upload(fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf'),
                                       user: @admin, slot: 'income_proof')
          result = ProofAttachmentService.attach_proof(application: application.reload, proof_type: :income, blob_or_file: replacement.signed_id,
                                                       scan_owner: @admin, admin: @admin, submission_method: :web)
          assert result[:success], result[:error]&.message
          Applications::ProofReviewer.new(application, @admin).review(
            proof_type: :income, status: status, decision_key: SecureRandom.uuid, reviewed_blob_id: replacement.id,
            rejection_reason: status == :rejected ? 'The income document is unreadable.' : nil
          )
        end
      end

      travel_to (approved_on + 10.days).in_time_zone.noon do
        assert_nothing_raised { Funding.validate!(application, source: 'icanconnect', on: rejected_on.prev_day) }
        assert_raises(Funding::Ineligible) { Funding.validate!(application, source: 'icanconnect', on: rejected_on + 5.days) }
        assert_nothing_raised { Funding.validate!(application, source: 'icanconnect') }
        assert_nothing_raised { Funding.validate!(application, source: 'mat', on: rejected_on + 5.days) }
        result = ::TrainingSessions::CompleteService.new(session, trainer, {
                                                           completed_at: (rejected_on + 5.days).in_time_zone.noon,
                                                           product_trained_on_id: application.equipment_items.sole.product_id,
                                                           duration_hours: 1, constituent_summary: 'We practiced using the device.', summary_locale: 'en'
                                                         }).call
        assert result.failure?
        assert_not_empty result.data.fetch(:training_session).errors[:funding_source]
        assert session.reload.status_scheduled?
        assert_nil session.completed_at
        assert_equal initial_service_on, session.funding_service_on
        assert application.reload.status_approved?
        assert_equal lifecycle, application.status_changes.order(:id).ids
      end
    end

    private

    def supplied_application(**attributes)
      application = nil
      travel_to @verified_on.in_time_zone.noon do
        application = approved_deafblind_application(**attributes)
        icc_order_with_unit(application: application)
      end
      application
    end
  end
end
