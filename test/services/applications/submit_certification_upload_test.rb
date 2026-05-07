# frozen_string_literal: true

require 'test_helper'

module Applications
  class SubmitCertificationUploadTest < ActiveSupport::TestCase
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      @application = create(:application, :in_progress,
                            medical_provider_name: 'Dr. Provider',
                            medical_provider_email: 'provider@example.com')
      @secure_request_form = create(:medical_provider_secure_request_form, application: @application)
      @file = fixture_file_upload(Rails.root.join('test/fixtures/files/medical_certification_valid.pdf'), 'application/pdf')
    end

    test 'attaches certification through attachment service and marks request submitted' do
      result = SubmitCertificationUpload.new(
        application: @application,
        medical_provider_secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_predicate result, :success?
      assert_predicate @secure_request_form.reload, :submitted?
      assert_predicate @application.reload.medical_certification, :attached?
      assert_predicate @application, :medical_certification_status_received?

      event = Event.find_by!(auditable: @application, action: 'cert_submitted_via_secure_form')
      assert_equal @secure_request_form.id, event.metadata.fetch('medical_provider_secure_request_form_id')
      assert_equal User.system_user, event.user

      status_change = ApplicationStatusChange.where(application: @application, change_type: :medical_certification).last
      assert_equal 'secure_form', status_change.metadata.fetch('submission_method')
    end

    test 'rejects unsupported file type without submitting request' do
      file = fixture_file_upload(Rails.root.join('test/fixtures/files/sample.txt'), 'text/plain')

      result = SubmitCertificationUpload.new(
        application: @application,
        medical_provider_secure_request_form: @secure_request_form,
        file: file
      ).call

      assert_not result.success?
      assert_predicate result.data.fetch(:errors), :any?
      assert_predicate @secure_request_form.reload, :status_sent?
      assert_not @application.reload.medical_certification.attached?
    end

    test 'rejects request form for a different application' do
      other_application = create(:application, :in_progress)

      result = SubmitCertificationUpload.new(
        application: other_application,
        medical_provider_secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.invalid_request'), result.message
      assert_predicate @secure_request_form.reload, :status_sent?
      assert_not other_application.reload.medical_certification.attached?
    end

    test 'rejects expired request form without attaching certification' do
      @secure_request_form.update!(expires_at: 1.minute.ago)

      result = SubmitCertificationUpload.new(
        application: @application,
        medical_provider_secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.expired'), result.message
      assert_predicate @secure_request_form.reload, :status_sent?
      assert_not @application.reload.medical_certification.attached?
    end

    test 'rejects revoked request form without attaching certification' do
      @secure_request_form.revoke!

      result = SubmitCertificationUpload.new(
        application: @application,
        medical_provider_secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.revoked'), result.message
      assert_predicate @secure_request_form.reload, :status_revoked?
      assert_not @application.reload.medical_certification.attached?
    end

    test 'rejects already submitted request form without attaching certification' do
      @secure_request_form.mark_submitted!

      result = SubmitCertificationUpload.new(
        application: @application,
        medical_provider_secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.already_submitted'), result.message
      assert_not @application.reload.medical_certification.attached?
    end
  end
end
