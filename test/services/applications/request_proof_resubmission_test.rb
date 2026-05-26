# frozen_string_literal: true

require 'test_helper'

module Applications
  class RequestProofResubmissionTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    setup do
      @actor = create(:admin)
      @application = create(:application, :in_progress)
      Current.paper_context = true
      @proof_review = create(:proof_review,
                             application: @application,
                             admin: @actor,
                             proof_type: :income,
                             status: :rejected,
                             rejection_reason: 'Missing income details')
      Current.paper_context = false
      @application.income_proof.purge if @application.income_proof.attached?
      @mailer_delivery = mock('proof-resubmission-mailer-delivery')
      @mailer_delivery.stubs(:deliver_now).returns(true)
      ApplicationNotificationsMailer.stubs(:proof_rejected).returns(@mailer_delivery)
      ApplicationNotificationsMailer.stubs(:proof_requested).returns(@mailer_delivery)
    end

    teardown do
      Current.reset
    end

    test 'creates proof request notification and delivers proof rejection email immediately' do
      @mailer_delivery.expects(:deliver_now).returns(true)

      result = RequestProofResubmission.new(application: @application, actor: @actor, proof_type: :income).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_predicate form, :kind_income_proof_resubmission?
      assert_predicate form, :recipient_channel_email?

      notification = Notification.find_by!(
        notifiable: @application,
        action: 'proof_resubmission_requested',
        recipient: @application.user
      )
      assert_equal form.id, notification.metadata.fetch('secure_request_form_id')
      assert_equal 'income', notification.metadata.fetch('proof_type')
      assert_not notification.metadata.key?('secure_upload_url')
    end

    test 'creates proof request when rejected attachment is still awaiting purge' do
      @application.update!(income_proof_status: :rejected)
      @application.income_proof.attach(
        io: StringIO.new('rejected proof still attached'),
        filename: 'rejected-income.pdf',
        content_type: 'application/pdf'
      )
      assert_predicate @application.income_proof, :attached?

      @mailer_delivery.expects(:deliver_now).returns(true)

      result = RequestProofResubmission.new(application: @application, actor: @actor, proof_type: :income).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_predicate form, :kind_income_proof_resubmission?
    end

    test 'creates proof request for rejected residency status without matching proof review' do
      application = create(:application, :in_progress, residency_proof_status: :rejected)
      application.residency_proof.attach(
        io: StringIO.new('rejected proof still attached'),
        filename: 'rejected-residency.pdf',
        content_type: 'application/pdf'
      )
      assert_empty application.proof_reviews.where(proof_type: :residency, status: :rejected)

      ApplicationNotificationsMailer.expects(:proof_rejected).never
      ApplicationNotificationsMailer
        .expects(:proof_requested)
        .with(
          application,
          :residency,
          secure_upload_url: regexp_matches(/secure_proof_form/),
          recipient: application.user
        )
        .returns(@mailer_delivery)
      @mailer_delivery.expects(:deliver_now).returns(true)

      result = RequestProofResubmission.new(application: application, actor: @actor, proof_type: :residency).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_predicate form, :kind_residency_proof_resubmission?
      assert_equal 'residency',
                   Notification.find_by!(notifiable: application, action: 'proof_resubmission_requested')
                               .metadata.fetch('proof_type')
    end

    test 'issued proof resubmission request appears in application audit logs' do
      result = RequestProofResubmission.new(application: @application, actor: @actor, proof_type: :income).call

      assert_predicate result, :success?
      notification = Notification.find_by!(
        notifiable: @application,
        action: 'proof_resubmission_requested',
        recipient: @application.user
      )

      with_mocked_attachments do
        logs = AuditLogBuilder.new(@application).build_deduplicated_audit_logs
        assert_includes logs, notification
      end
    end

    test 'delivery error reporting redacts secure proof upload urls' do
      raw_url = 'https://example.test/secure_proof_form?token=raw-proof-token'
      @mailer_delivery.stubs(:deliver_now).raises(StandardError, "smtp rendered #{raw_url}")

      if Rails.respond_to?(:error)
        Rails.error.expects(:report).with do |reported_error, handled:, context:|
          handled == true &&
            reported_error.message == 'smtp rendered [REDACTED_URL]' &&
            reported_error.message.exclude?(raw_url) &&
            reported_error.message.exclude?('raw-proof-token') &&
            context[:error_class] == 'StandardError' &&
            context[:proof_type] == 'income' &&
            context[:secure_request_form_ids].present?
        end
      end

      result = RequestProofResubmission.new(application: @application, actor: @actor, proof_type: :income).call

      assert_not result.success?
      assert_predicate result.data.fetch(:secure_request_forms).first.reload, :revoked?
    end

    test 'delivers proof rejection email to resolved guardian recipient' do
      guardian = create(:constituent, first_name: 'Guardian')
      dependent = create(:constituent, first_name: 'Dependent')
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, :in_progress, user: dependent, managing_guardian: guardian)
      Current.paper_context = true
      proof_review = create(:proof_review,
                            application: application,
                            admin: @actor,
                            proof_type: :income,
                            status: :rejected,
                            rejection_reason: 'Missing income details')
      Current.paper_context = false
      application.income_proof.purge if application.income_proof.attached?

      @mailer_delivery.expects(:deliver_now).returns(true)
      ApplicationNotificationsMailer
        .expects(:proof_rejected)
        .with(
          application,
          proof_review,
          secure_upload_url: regexp_matches(/secure_proof_form/),
          recipient: guardian
        )
        .returns(@mailer_delivery)

      result = RequestProofResubmission.new(application: application, actor: @actor, proof_type: :income).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_equal guardian, form.recipient
      assert_equal guardian, Notification.find_by!(notifiable: application, action: 'proof_resubmission_requested').recipient
    end

    test 'default proof resubmission follows separate dependent effective email path' do
      guardian = create(:constituent, email: "guardian.proof.#{SecureRandom.hex(3)}@example.com")
      dependent_email = "dependent.proof.#{SecureRandom.hex(3)}@example.com"
      dependent = create(:constituent, email: dependent_email, dependent_email: dependent_email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, :in_progress,
                           user: dependent,
                           managing_guardian: guardian,
                           income_proof_status: :rejected)
      Current.paper_context = true
      create(:proof_review, application: application, admin: @actor, proof_type: :income, status: :rejected,
                            rejection_reason: 'Missing income details')
      Current.paper_context = false
      application.income_proof.purge if application.income_proof.attached?

      result = RequestProofResubmission.new(application: application, actor: @actor, proof_type: :income).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_equal dependent, form.recipient
      assert_equal dependent_email, form.recipient_email
      assert_equal dependent, Notification.find_by!(notifiable: application, action: 'proof_resubmission_requested').recipient
    end

    test 'explicit multi-recipient proof resubmission creates one request per selected recipient' do
      guardian = create(:constituent)
      dependent = create(:constituent, dependent_email: guardian.email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, :in_progress,
                           user: dependent,
                           managing_guardian: guardian,
                           income_proof_status: :rejected)
      Current.paper_context = true
      create(:proof_review, application: application, admin: @actor, proof_type: :income, status: :rejected,
                            rejection_reason: 'Missing income details')
      Current.paper_context = false
      application.income_proof.purge if application.income_proof.attached?

      result = assert_difference('SecureRequestForm.count', 2) do
        RequestProofResubmission.new(
          application: application,
          actor: @actor,
          proof_type: :income,
          recipient_ids: [dependent.id, guardian.id],
          deliver_request: false
        ).call
      end

      assert_predicate result, :success?
      forms = result.data.fetch(:secure_request_forms)
      assert_equal [dependent.id, guardian.id], forms.map(&:recipient_id)
      assert_equal 1, forms.map(&:request_batch_id).uniq.size
      assert_equal [dependent.id, guardian.id],
                   Notification.where(notifiable: application, action: 'proof_resubmission_requested').order(:id).pluck(:recipient_id)
    end

    test 'sms request sends token-safe SMS and records requested channel' do
      @application.user.update!(phone: '410-555-0100', phone_type: 'text')
      SmsService.expects(:send_message).with(
        @application.user.phone,
        regexp_matches(/secure_proof_form/),
        sensitive: true,
        context: has_entries(
          application_id: @application.id,
          recipient_id: @application.user_id,
          recipient_channel: 'sms'
        )
      ).returns(true)

      result = RequestProofResubmission.new(application: @application, actor: @actor, proof_type: :income).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      notification = Notification.find_by!(
        notifiable: @application,
        action: 'proof_resubmission_requested',
        recipient: @application.user
      )
      assert_predicate form, :recipient_channel_sms?
      assert_equal 'email', notification.metadata.fetch('channel')
      assert_equal 'sms', notification.metadata.fetch('recipient_channel')
      assert_equal 'sms', notification.metadata.fetch('requested_recipient_channel')
    end

    test 'resend after cooldown revokes prior link and creates replacement' do
      first_result = RequestProofResubmission.new(application: @application, actor: @actor, proof_type: :income).call
      original = first_result.data.fetch(:secure_request_forms).first

      travel_to original.sent_at + 2.hours do
        result = RequestProofResubmission.new(
          application: @application,
          actor: @actor,
          proof_type: :income,
          resend_of: original
        ).call

        assert_predicate result, :success?
      end

      assert_predicate original.reload, :revoked?
      assert_equal 1, SecureRequestForm.open_income_proof_for_recipient(
        application_id: @application.id,
        recipient_id: @application.user_id
      ).count
    end

    test 'public recovery is neutral during cooldown' do
      first_result = RequestProofResubmission.new(application: @application, actor: @actor, proof_type: :income).call
      original = first_result.data.fetch(:secure_request_forms).first

      result = RequestProofResubmission.new(
        application: @application,
        actor: @actor,
        proof_type: :income,
        resend_of: original,
        public_recovery: true
      ).call

      assert_predicate result, :success?
      assert_predicate original.reload, :status_sent?
    end

    test 'can create a public recovery link without sending the proof rejection email again' do
      @mailer_delivery.expects(:deliver_now).never

      result = RequestProofResubmission.new(
        application: @application,
        actor: @actor,
        proof_type: :income,
        recipient_ids: [@application.user_id],
        public_recovery: true,
        deliver_request: false
      ).call

      assert_predicate result, :success?
      assert_match %r{\Ahttp://.*secure_proof_form\?token=}, result.data.fetch(:secure_upload_url)
      assert_equal 1, result.data.fetch(:secure_request_forms).size
    end

    test 'fails when proof type is unsupported' do
      result = RequestProofResubmission.new(
        application: @application,
        actor: @actor,
        proof_type: :medical_certification
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.proof_resubmission.messages.invalid_proof_type', locale: @actor.effective_locale),
                   result.message
    end

    test 'creates proof request and delivers generic proof request email when proof is still missing' do
      application = create(:application, :in_progress, id_proof_status: :not_reviewed)

      @mailer_delivery.expects(:deliver_now).returns(true)
      ApplicationNotificationsMailer
        .expects(:proof_requested)
        .with(
          application,
          :id,
          secure_upload_url: regexp_matches(/secure_proof_form/),
          recipient: application.user
        )
        .returns(@mailer_delivery)

      result = RequestProofResubmission.new(
        application: application,
        actor: @actor,
        proof_type: :id
      ).call

      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).first
      assert_predicate form, :kind_id_proof_resubmission?
      assert_equal 'id', Notification.find_by!(notifiable: application, action: 'proof_resubmission_requested').metadata.fetch('proof_type')
    end

    test 'paper application with email preference sends secure proof request email with upload url' do
      application = create(:application, :in_progress, id_proof_status: :not_reviewed, submission_method: :paper)
      application.user.update!(communication_preference: :email)

      @mailer_delivery.expects(:deliver_now).returns(true)
      ApplicationNotificationsMailer
        .expects(:proof_requested)
        .with(
          application,
          :id,
          secure_upload_url: regexp_matches(/secure_proof_form/),
          recipient: application.user
        )
        .returns(@mailer_delivery)

      result = RequestProofResubmission.new(
        application: application,
        actor: @actor,
        proof_type: :id
      ).call

      assert_predicate result, :success?
      assert_predicate result.data.fetch(:secure_request_forms).first, :recipient_channel_email?
    end

    test 'letter preference proof request does not pass bearer url to mailer' do
      application = create(:application, :in_progress, id_proof_status: :not_reviewed)
      application.user.update!(communication_preference: :letter)

      @mailer_delivery.expects(:deliver_now).returns(true)
      ApplicationNotificationsMailer
        .expects(:proof_requested)
        .with(
          application,
          :id,
          secure_upload_url: nil,
          recipient: application.user
        )
        .returns(@mailer_delivery)

      result = RequestProofResubmission.new(
        application: application,
        actor: @actor,
        proof_type: :id
      ).call

      assert_predicate result, :success?
      assert_predicate result.data.fetch(:secure_request_forms).first, :recipient_channel_letter?
    end

    test 'fails when proof upload request is not needed' do
      application = create(:application, :in_progress, id_proof_status: :approved)

      result = RequestProofResubmission.new(
        application: application,
        actor: @actor,
        proof_type: :id
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.proof_resubmission.messages.request_not_needed', locale: @actor.effective_locale),
                   result.message
    end

    test 'staff resend during cooldown fails without creating replacement' do
      first_result = RequestProofResubmission.new(application: @application, actor: @actor, proof_type: :income).call
      original = first_result.data.fetch(:secure_request_forms).first

      result = assert_no_difference('SecureRequestForm.count') do
        RequestProofResubmission.new(
          application: @application,
          actor: @actor,
          proof_type: :income,
          resend_of: original
        ).call
      end

      assert_not result.success?
      assert_match(/minute/, result.message)
      assert_predicate original.reload, :status_sent?
    end

    test 'staff can send a replacement immediately after manually revoking the latest proof request' do
      application = create(:application, :in_progress, id_proof_status: :not_reviewed)
      original = create(
        :secure_request_form,
        :revoked,
        application: application,
        recipient: application.user,
        kind: :id_proof_resubmission,
        sent_at: Time.current
      )

      @mailer_delivery.expects(:deliver_now).returns(true)

      result = assert_difference('SecureRequestForm.count', 1) do
        RequestProofResubmission.new(
          application: application,
          actor: @actor,
          proof_type: :id
        ).call
      end

      assert_predicate result, :success?
      assert_predicate original.reload, :status_revoked?
      replacement = result.data.fetch(:secure_request_forms).first
      assert_predicate replacement, :kind_id_proof_resubmission?
      assert_predicate replacement, :status_sent?
    end
  end
end
