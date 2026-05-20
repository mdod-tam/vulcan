# frozen_string_literal: true

require 'test_helper'

module Applications
  class SubmitProofResubmissionTest < ActiveSupport::TestCase
    include ActionDispatch::TestProcess::FixtureFile

    setup do
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
      assert_equal @secure_request_form.id, event.metadata.fetch('secure_request_form_id')
      assert_equal 'income', event.metadata.fetch('proof_type')

      attachment_event = Event.where(auditable: @application, action: 'income_proof_attached').order(:created_at).last
      assert_equal 'secure_form', attachment_event.metadata.fetch('submission_method')
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
  end
end
