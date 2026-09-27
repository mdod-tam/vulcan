# frozen_string_literal: true

require 'test_helper'

module Applications
  class SubmitProofResubmissionTest < ActiveSupport::TestCase
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      @system_audit_actor = create(:admin, email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
      @application = create(:application, :in_progress)
      @secure_request_form = create(:secure_request_form, kind: :income_proof_resubmission, application: @application)
      @file = fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
    end

    test 'attaches proof through ProofAttachmentService and marks request submitted' do
      result = SubmitProofResubmission.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_predicate result, :success?
      assert_predicate @secure_request_form.reload, :submitted?
      assert_predicate @application.reload.income_proof, :attached?
      assert_predicate @application, :income_proof_status_not_reviewed?

      event = Event.find_by!(auditable: @application, action: 'proof_submitted_via_secure_form')
      assert_equal @system_audit_actor.id, event.user_id
      assert_equal @secure_request_form.id, event.metadata.fetch('secure_request_form_id')
      assert_equal @secure_request_form.recipient_id, event.metadata.fetch('recipient_user_id')
      assert_equal @secure_request_form.delivery_owner_id, event.metadata.fetch('delivery_owner_id')
      assert_equal @secure_request_form.delivery_source, event.metadata.fetch('delivery_source')
      assert_equal @secure_request_form.recipient_channel, event.metadata.fetch('recipient_channel')
      assert_equal 'income', event.metadata.fetch('proof_type')

      attachment_event = Event.where(auditable: @application, action: 'income_proof_attached').order(:created_at).last
      assert_equal 'secure_form', attachment_event.metadata.fetch('submission_method')
    end

    test 'secure id proof upload delivers document received notification' do
      application = create(:application, :in_progress, id_proof_status: :not_reviewed)
      secure_request_form = create(:secure_request_form, kind: :id_proof_resubmission, application: application)
      mail_delivery = mock('id-proof-received-mail-delivery')
      mail_delivery.expects(:deliver_later).returns(true)
      ApplicationNotificationsMailer.expects(:proof_received)
                                    .with(application, 'id')
                                    .returns(mail_delivery)

      result = SubmitProofResubmission.new(
        application: application,
        secure_request_form: secure_request_form,
        file: @file
      ).call

      assert_predicate result, :success?
      assert_predicate secure_request_form.reload, :submitted?
      assert_predicate application.reload.id_proof, :attached?

      notification = Notification.find_by!(notifiable: application, action: 'id_proof_attached')
      assert_equal 'id', notification.metadata.fetch('proof_type')
      assert_not_equal 'error', notification.delivery_status
      assert_nil notification.metadata&.dig('delivery_error', 'message')
    end

    test 'rejects unsupported file type without submitting request' do
      file = fixture_file_upload(Rails.root.join('test/fixtures/files/sample.txt'), 'text/plain')

      result = SubmitProofResubmission.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: file
      ).call

      assert_not result.success?
      assert_predicate result.data.fetch(:errors), :any?
      assert_predicate @secure_request_form.reload, :status_sent?
    end

    test 'rejects request form for a different application' do
      other_application = create(:application, :in_progress)

      result = SubmitProofResubmission.new(
        application: other_application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.proof_resubmission.messages.invalid_request'), result.message
      assert_predicate @secure_request_form.reload, :status_sent?
      assert_not other_application.reload.income_proof.attached?
    end

    test 'rejects expired request form without attaching proof' do
      @secure_request_form.update!(expires_at: 1.minute.ago)

      result = SubmitProofResubmission.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.proof_resubmission.messages.expired'), result.message
      assert_predicate @secure_request_form.reload, :status_sent?
      assert_not @application.reload.income_proof.attached?
    end

    test 'rejects revoked request form without attaching proof' do
      @secure_request_form.revoke!

      result = SubmitProofResubmission.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.proof_resubmission.messages.revoked'), result.message
      assert_predicate @secure_request_form.reload, :status_revoked?
      assert_not @application.reload.income_proof.attached?
    end

    test 'rejects already submitted request form without attaching proof' do
      @secure_request_form.mark_submitted!

      result = SubmitProofResubmission.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.proof_resubmission.messages.already_submitted'), result.message
      assert_not @application.reload.income_proof.attached?
    end

    test 'refuses an approved proof without replacing it and records the refusal' do
      attach_income_proof(@application)
      @application.update_columns(income_proof_status: Application.income_proof_statuses[:approved])
      original_blob_id = @application.reload.income_proof.blob.id

      result = SubmitProofResubmission.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.proof_resubmission.messages.no_longer_needed'), result.message
      assert_predicate @application.reload, :income_proof_status_approved?
      assert_equal original_blob_id, @application.income_proof.blob.id
      assert_predicate @secure_request_form.reload, :status_sent?

      event = Event.find_by!(auditable: @application, action: 'proof_secure_submission_refused')
      assert_equal @secure_request_form.id, event.metadata.fetch('secure_request_form_id')
      assert_equal 'income', event.metadata.fetch('proof_type')
      assert_equal 'approved', event.metadata.fetch('proof_status')
    end

    test 'refuses a proof uploaded through another path after the link was sent' do
      attach_income_proof(@application)
      @application.update_columns(income_proof_status: Application.income_proof_statuses[:not_reviewed])

      result = SubmitProofResubmission.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.proof_resubmission.messages.no_longer_needed'), result.message
      assert_predicate @secure_request_form.reload, :status_sent?
    end

    test 'issuance and submission agree for every proof state' do
      admin = create(:admin)
      states = {
        'approved with a document' => [:approved, true, false],
        'rejected with a document' => [:rejected, true, true],
        'rejected without a document' => [:rejected, false, true],
        'not reviewed with a document' => [:not_reviewed, true, false],
        'never uploaded' => [:not_reviewed, false, true]
      }

      states.each do |label, (status, attached, requestable)|
        application = create(:application, :in_progress)
        attach_income_proof(application) if attached
        application.update_columns(income_proof_status: Application.income_proof_statuses[status])
        application.reload

        assert_equal requestable, application.proof_requestable_via_secure_form?(:income), label

        issue_result = RequestProofResubmission.new(application: application, actor: admin, proof_type: 'income').call
        issue_refused = issue_result.message == I18n.t('applications.proof_resubmission.messages.request_not_needed')
        assert_equal !requestable, issue_refused, "issuance: #{label}"

        # Only one active link per recipient is allowed; clear any link issuance created.
        application.secure_request_forms.update_all(status: SecureRequestForm.statuses[:revoked], revoked_at: Time.current)
        form = create(:secure_request_form, kind: :income_proof_resubmission, application: application)
        submit_result = SubmitProofResubmission.new(application: application, secure_request_form: form, file: @file).call
        assert_equal requestable, submit_result.success?, "submission: #{label}"
      end
    end

    private

    def attach_income_proof(application)
      application.income_proof.attach(
        io: Rails.root.join('test/fixtures/files/income_proof.pdf').open,
        filename: 'existing_income_proof.pdf',
        content_type: 'application/pdf'
      )
    end
  end
end
