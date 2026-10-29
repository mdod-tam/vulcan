# frozen_string_literal: true

require 'test_helper'

module Applications
  class SubmitCertificationUploadTest < ActiveSupport::TestCase
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      ensure_system_audit_actor!
      @application = create(:application, :in_progress,
                            certifying_professional_name: 'Dr. Provider',
                            certifying_professional_email: 'provider@example.com')
      @secure_request_form = create(:certification_upload_form, application: @application)
      upload = fixture_file_upload(Rails.root.join('test/fixtures/files/disability_certification_valid.pdf'), 'application/pdf')
      @file = scanned_upload(upload, secure_form: @secure_request_form, purpose: :certification,
                                     slot: 'disability_certification').signed_id
    end

    test 'attaches certification through attachment service and marks request submitted' do
      result = SubmitCertificationUpload.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_predicate result, :success?
      assert_predicate @secure_request_form.reload, :submitted?
      assert_predicate @application.reload.disability_certification, :attached?
      assert_predicate @application, :disability_certification_status_received?

      event = Event.find_by!(auditable: @application, action: 'cert_submitted_via_secure_form')
      assert_equal @secure_request_form.id, event.metadata.fetch('secure_request_form_id')
      assert_equal User.system_user, event.user

      status_change = ApplicationStatusChange.where(application: @application, change_type: :disability_certification).last
      assert_equal 'secure_form', status_change.metadata.fetch('submission_method')
    end

    test 'retains secure upload as additional certification when DocuSeal primary already exists' do
      @application.update!(disability_certification_status: :received)
      @application.disability_certification.attach(
        io: StringIO.new('docuseal primary content'),
        filename: 'disability_cert_docuseal_123.pdf',
        content_type: 'application/pdf',
        metadata: { source: 'docuseal' }
      )

      DisabilityCertificationAttachmentService.expects(:attach_certification).never

      assert_no_difference -> { ApplicationStatusChange.where(application: @application).count } do
        result = SubmitCertificationUpload.new(
          application: @application,
          secure_request_form: @secure_request_form,
          file: @file
        ).call

        assert_predicate result, :success?
      end

      @application.reload
      assert_predicate @secure_request_form.reload, :submitted?
      assert_equal 'received', @application.disability_certification_status
      assert_equal 'disability_cert_docuseal_123.pdf', @application.disability_certification.blob.filename.to_s
      assert_equal 1, @application.additional_disability_certifications.count

      additional_blob = @application.additional_disability_certifications.first.blob
      assert_equal 'disability_certification_valid.pdf', additional_blob.filename.to_s
      assert_equal 'secure_form', additional_blob.metadata.fetch('source')
      assert_equal @secure_request_form.id, additional_blob.metadata.fetch('secure_request_form_id')
      assert_equal @secure_request_form.request_batch_id, additional_blob.metadata.fetch('request_batch_id')
      assert_equal @secure_request_form.recipient_email, additional_blob.metadata.fetch('provider_email')

      event = Event.find_by!(auditable: @application, action: 'cert_submitted_via_secure_form')
      assert_equal @secure_request_form.id, event.metadata.fetch('secure_request_form_id')
      assert_equal 'p***@e***.com', event.metadata.fetch('provider_email')
      assert_equal @secure_request_form.request_batch_id, event.metadata.fetch('request_batch_id')
      assert_equal 'additional_disability_certification', event.metadata.fetch('retained_as')
      assert_equal additional_blob.id, event.metadata.fetch('additional_disability_certification_blob_id')
    end

    test 'submission audit failure rolls back certification and leaves the form active' do
      original_log = AuditEventService.method(:log)
      failing_audit = lambda do |**attributes|
        raise ActiveRecord::RecordInvalid, Event.new if attributes[:action] == 'cert_submitted_via_secure_form'

        original_log.call(**attributes)
      end

      assert_no_difference [-> { Event.count }, -> { @application.status_changes.count }] do
        AuditEventService.stub(:log, failing_audit) do
          result = SubmitCertificationUpload.new(application: @application,
                                                 secure_request_form: @secure_request_form, file: @file).call
          assert_predicate result, :failure?
        end
      end
      assert_not_predicate @application.reload.disability_certification, :attached?
      assert_predicate @secure_request_form.reload, :active_for_public_use?
      assert_nil @secure_request_form.submitted_at
    end

    test 'retains secure upload as additional certification for legacy DocuSeal primary without blob metadata' do
      @application.update!(disability_certification_status: :received)
      @application.disability_certification.attach(
        io: StringIO.new('legacy docuseal primary content'),
        filename: 'legacy_docuseal_primary.pdf',
        content_type: 'application/pdf'
      )
      ApplicationStatusChange.create!(
        application: @application,
        user: User.system_user,
        from_status: 'requested',
        to_status: 'received',
        change_type: 'disability_certification',
        metadata: {
          change_type: 'disability_certification',
          submission_method: 'docuseal'
        }
      )

      assert_no_difference -> { ApplicationStatusChange.where(application: @application).count } do
        result = SubmitCertificationUpload.new(
          application: @application,
          secure_request_form: @secure_request_form,
          file: @file
        ).call

        assert_predicate result, :success?
      end

      @application.reload
      assert_predicate @secure_request_form.reload, :submitted?
      assert_equal 'legacy_docuseal_primary.pdf', @application.disability_certification.blob.filename.to_s
      assert_equal 1, @application.additional_disability_certifications.count
      assert_equal 'secure_form', @application.additional_disability_certifications.first.blob.metadata.fetch('source')
    end

    test 'attaches secure upload as primary when DocuSeal completed without primary certification' do
      @application.update!(
        document_signing_status: :signed,
        document_signing_signed_at: Time.current,
        disability_certification_status: :requested
      )

      result = SubmitCertificationUpload.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_predicate result, :success?
      assert_predicate @secure_request_form.reload, :submitted?

      @application.reload
      assert_predicate @application.disability_certification, :attached?
      assert_equal 'disability_certification_valid.pdf', @application.disability_certification.blob.filename.to_s
      assert_equal 0, @application.additional_disability_certifications.count
      assert_predicate @application, :disability_certification_status_received?

      status_change = ApplicationStatusChange.where(application: @application, change_type: :disability_certification).last
      assert_equal 'secure_form', status_change.metadata.fetch('submission_method')
    end

    test 'rejects unsupported file type without submitting request' do
      file = fixture_file_upload(Rails.root.join('test/fixtures/files/sample.txt'), 'text/plain')

      result = SubmitCertificationUpload.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: file
      ).call

      assert_not result.success?
      assert_predicate result.data.fetch(:errors), :any?
      assert_predicate @secure_request_form.reload, :status_sent?
      assert_not @application.reload.disability_certification.attached?
    end

    test 'rejects request form for a different application' do
      other_application = create(:application, :in_progress)

      result = SubmitCertificationUpload.new(
        application: other_application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.invalid_request'), result.message
      assert_predicate @secure_request_form.reload, :status_sent?
      assert_not other_application.reload.disability_certification.attached?
    end

    test 'rejects expired request form without attaching certification' do
      @secure_request_form.update!(expires_at: 1.minute.ago)

      result = SubmitCertificationUpload.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.expired'), result.message
      assert_predicate @secure_request_form.reload, :status_sent?
      assert_not @application.reload.disability_certification.attached?
    end

    test 'rejects revoked request form without attaching certification' do
      @secure_request_form.revoke!

      result = SubmitCertificationUpload.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.revoked'), result.message
      assert_predicate @secure_request_form.reload, :status_revoked?
      assert_not @application.reload.disability_certification.attached?
    end

    test 'rejects already submitted request form without attaching certification' do
      @secure_request_form.mark_submitted!

      result = SubmitCertificationUpload.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.already_submitted'), result.message
      assert_not @application.reload.disability_certification.attached?
    end

    test 'refuses an upload for an archived application and records the refusal' do
      @application.update_columns(status: Application.statuses[:archived])
      status_before = @application.reload.disability_certification_status

      result = submit_upload

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.no_longer_needed'), result.message
      @application.reload
      assert_not @application.disability_certification.attached?
      assert_equal 0, @application.additional_disability_certifications.count
      assert_equal status_before, @application.disability_certification_status
      assert_predicate @secure_request_form.reload, :status_sent?, 'a refused upload leaves the link unused'

      event = Event.find_by!(auditable: @application, action: 'cert_secure_submission_refused')
      assert_equal @secure_request_form.id, event.metadata.fetch('secure_request_form_id')
      assert_equal 'certification_no_longer_requestable', event.metadata.fetch('reason')
      assert_equal User.system_user, event.user
      assert_not Event.exists?(auditable: @application, action: 'cert_submitted_via_secure_form')
    end

    test 'an archived refusal still shows the neutral message when its audit event cannot be written' do
      @application.update_columns(status: Application.statuses[:archived])
      failed_event = Event.new
      failed_event.errors.add(:base, 'Metadata is invalid')
      AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(failed_event))

      result = submit_upload

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.no_longer_needed'), result.message
      assert_not_includes result.message, 'Metadata is invalid'
      assert_predicate @secure_request_form.reload, :status_sent?
      assert_not @application.reload.disability_certification.attached?
    end

    test 'a correction requested after a DocuSeal rejection replaces the primary certification' do
      attach_docuseal_primary
      record_certification_rejection(at: 2.days.ago)
      @secure_request_form.update!(sent_at: 1.day.ago)

      result = submit_upload

      assert_predicate result, :success?
      @application.reload
      assert_predicate @application, :disability_certification_status_received?
      assert_equal 'disability_certification_valid.pdf', @application.disability_certification.blob.filename.to_s
      assert_equal 0, @application.additional_disability_certifications.count
    end

    test 'an upload for a request sent before the latest rejection is kept aside for review' do
      attach_docuseal_primary
      @secure_request_form.update!(sent_at: 3.days.ago)
      record_certification_rejection(at: 1.day.ago)

      result = submit_upload

      assert_predicate result, :success?
      @application.reload
      assert_predicate @application, :disability_certification_status_rejected?
      assert_equal 'docuseal_primary.pdf', @application.disability_certification.blob.filename.to_s
      assert_equal 'request_predates_rejection',
                   @application.additional_disability_certifications.first.blob.metadata['retention_reason']
    end

    test 'an upload after approval never replaces the approved certification' do
      @application.disability_certification.attach(io: StringIO.new('approved'), filename: 'approved.pdf', content_type: 'application/pdf')
      @application.update!(disability_certification_status: :approved)

      result = submit_upload

      assert_predicate result, :success?
      @application.reload
      assert_predicate @application, :disability_certification_status_approved?
      assert_equal 'approved.pdf', @application.disability_certification.blob.filename.to_s
      assert_equal 'certification_approved',
                   @application.additional_disability_certifications.first.blob.metadata['retention_reason']

      event = Event.find_by!(auditable: @application, action: 'cert_submitted_via_secure_form')
      assert_equal 'certification_approved', event.metadata['retention_reason']
    end

    private

    def submit_upload
      SubmitCertificationUpload.new(
        application: @application,
        secure_request_form: @secure_request_form,
        file: @file
      ).call
    end

    def attach_docuseal_primary
      @application.disability_certification.attach(
        io: StringIO.new('docuseal primary content'),
        filename: 'docuseal_primary.pdf',
        content_type: 'application/pdf',
        metadata: { source: 'docuseal' }
      )
    end

    def record_certification_rejection(at:)
      @application.update!(disability_certification_status: :rejected)
      ApplicationStatusChange.create!(application: @application, user: User.system_user, from_status: 'received',
                                      to_status: 'rejected', change_type: 'disability_certification', changed_at: at)
    end
  end
end
