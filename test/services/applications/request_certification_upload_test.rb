# frozen_string_literal: true

require 'test_helper'

module Applications
  class RequestCertificationUploadTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    setup do
      @actor = create(:admin)
      @application = create(:application, :in_progress,
                            medical_provider_name: 'Dr. Provider',
                            medical_provider_email: 'provider@example.com')
    end

    test 'fails explicitly when provider email is missing' do
      application = create(:application, :draft, medical_provider_email: nil)

      result = assert_no_difference('MedicalProviderSecureRequestForm.count') do
        RequestCertificationUpload.new(application: application, actor: @actor).call
      end

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.provider_email_required', locale: @actor.effective_locale),
                   result.message
    end

    test 'creates secure cert upload form and audit-only notification' do
      result = assert_difference('MedicalProviderSecureRequestForm.count', 1) do
        assert_difference("Notification.where(action: 'cert_upload_requested').count", 1) do
          RequestCertificationUpload.new(application: @application, actor: @actor).call
        end
      end

      assert_predicate result, :success?
      form = result.data.fetch(:medical_provider_secure_request_form)
      token = Rack::Utils.parse_nested_query(URI.parse(result.data.fetch(:secure_upload_url)).query).fetch('token')
      notification = Notification.find_by!(notifiable: @application, action: 'cert_upload_requested')

      assert_equal form.id, MedicalProviderSecureRequestForm.from_public_token(token).id
      assert_predicate form, :kind_certification_upload?
      assert_equal 'provider@example.com', form.provider_email
      assert_equal 'Dr. Provider', form.provider_name
      assert_equal form.id, notification.metadata.fetch('medical_provider_secure_request_form_id')
      assert_equal 'provider@example.com', notification.metadata.fetch('provider_email')
      assert_equal 'Dr. Provider', notification.metadata.fetch('provider_name')
      assert_not notification.metadata.key?('secure_upload_url')
      assert_not notification.metadata.key?('raw_token')
    end

    test 'cert upload tracking notification follows guardian effective email path while provider receives secure link' do
      guardian = create(:constituent, email: "guardian.cert.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.cert.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, :in_progress,
                           user: dependent,
                           managing_guardian: guardian,
                           medical_provider_name: 'Dr. Provider',
                           medical_provider_email: 'provider-tracking@example.com')

      result = RequestCertificationUpload.new(application: application, actor: @actor).call

      assert_predicate result, :success?
      form = result.data.fetch(:medical_provider_secure_request_form)
      notification = Notification.find_by!(notifiable: application, action: 'cert_upload_requested')

      assert_equal 'provider-tracking@example.com', form.provider_email
      assert_equal guardian, notification.recipient
    end

    test 'cert upload tracking notification follows separate dependent effective email path while provider receives secure link' do
      guardian = create(:constituent, email: "guardian.cert.#{SecureRandom.hex(3)}@example.com")
      dependent_email = "dependent.cert.#{SecureRandom.hex(3)}@example.com"
      dependent = create(:constituent, email: dependent_email, dependent_email: dependent_email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, :in_progress,
                           user: dependent,
                           managing_guardian: guardian,
                           medical_provider_name: 'Dr. Provider',
                           medical_provider_email: 'provider-dependent@example.com')

      result = RequestCertificationUpload.new(application: application, actor: @actor).call

      assert_predicate result, :success?
      form = result.data.fetch(:medical_provider_secure_request_form)
      notification = Notification.find_by!(notifiable: application, action: 'cert_upload_requested')

      assert_equal 'provider-dependent@example.com', form.provider_email
      assert_equal dependent, notification.recipient
    end

    test 'issued certification upload request appears in application audit logs' do
      result = RequestCertificationUpload.new(application: @application, actor: @actor).call

      assert_predicate result, :success?
      notification = Notification.find_by!(notifiable: @application, action: 'cert_upload_requested')

      with_mocked_attachments do
        logs = AuditLogBuilder.new(@application).build_deduplicated_audit_logs
        assert_includes logs, notification
      end
    end

    test 'transitions initial not requested status to requested with audit trail' do
      assert_predicate @application, :medical_certification_status_not_requested?

      assert_difference('ApplicationStatusChange.where(change_type: :medical_certification).count', 1) do
        assert_difference("Event.where(auditable: @application, action: 'medical_certification_requested').count", 1) do
          RequestCertificationUpload.new(application: @application, actor: @actor).call
        end
      end

      assert_predicate @application.reload, :medical_certification_status_requested?
      status_change = ApplicationStatusChange.where(application: @application, change_type: :medical_certification).last
      assert_equal 'not_requested', status_change.from_status
      assert_equal 'requested', status_change.to_status
      assert_equal 'secure_form', status_change.metadata.fetch('submission_method')
    end

    test 'initial request transition does not require unrelated proof attachments' do
      previous_validation_env = ENV.fetch('REQUIRE_PROOF_VALIDATIONS', nil)
      ENV['REQUIRE_PROOF_VALIDATIONS'] = 'true'
      Current.skip_proof_validation = nil
      application = create(:application, :in_progress,
                           medical_provider_name: 'Dr. Provider',
                           medical_provider_email: 'provider@example.com')
      assert_not application.income_proof.attached?
      assert_not application.residency_proof.attached?

      result = assert_difference('MedicalProviderSecureRequestForm.count', 1) do
        RequestCertificationUpload.new(application: application, actor: @actor).call
      end

      assert_predicate result, :success?
      assert_predicate application.reload, :medical_certification_status_requested?
      assert_nil Current.skip_proof_validation
    ensure
      if previous_validation_env.nil?
        ENV.delete('REQUIRE_PROOF_VALIDATIONS')
      else
        ENV['REQUIRE_PROOF_VALIDATIONS'] = previous_validation_env
      end
      Current.skip_proof_validation = nil
    end

    test 'does not overwrite rejected certification status' do
      @application.update!(medical_certification_status: :rejected)

      result = RequestCertificationUpload.new(application: @application, actor: @actor).call

      assert_predicate result, :success?
      assert_predicate @application.reload, :medical_certification_status_rejected?
    end

    test 'staff resend during cooldown fails without creating replacement' do
      first_result = RequestCertificationUpload.new(application: @application, actor: @actor).call
      original = first_result.data.fetch(:medical_provider_secure_request_form)

      result = assert_no_difference('MedicalProviderSecureRequestForm.count') do
        RequestCertificationUpload.new(
          application: @application,
          actor: @actor,
          resend_of: original
        ).call
      end

      assert_not result.success?
      assert_match(/minute/, result.message)
      assert_predicate original.reload, :status_sent?
    end

    test 'resend after cooldown revokes prior link and creates replacement' do
      first_result = RequestCertificationUpload.new(application: @application, actor: @actor).call
      original = first_result.data.fetch(:medical_provider_secure_request_form)

      travel_to original.sent_at + 2.hours do
        result = assert_difference("Event.where(auditable: @application, action: 'cert_upload_request_revoked').count", 1) do
          RequestCertificationUpload.new(
            application: @application,
            actor: @actor,
            resend_of: original
          ).call
        end

        assert_predicate result, :success?
      end

      assert_predicate original.reload, :revoked?
      revocation_event = Event.find_by!(auditable: @application, action: 'cert_upload_request_revoked')
      assert_equal original.id, revocation_event.metadata.fetch('medical_provider_secure_request_form_id')
      assert_equal 'replacement_request', revocation_event.metadata.fetch('reason')
      assert_equal 1, MedicalProviderSecureRequestForm.open_certification_upload_for_provider(
        application_id: @application.id,
        provider_email: @application.medical_provider_email
      ).count
    end

    test 'revoked certification upload request appears in application audit logs' do
      first_result = RequestCertificationUpload.new(application: @application, actor: @actor).call
      original = first_result.data.fetch(:medical_provider_secure_request_form)

      travel_to original.sent_at + 2.hours do
        RequestCertificationUpload.new(
          application: @application,
          actor: @actor,
          resend_of: original
        ).call
      end

      revocation_event = Event.find_by!(auditable: @application, action: 'cert_upload_request_revoked')

      with_mocked_attachments do
        logs = AuditLogBuilder.new(@application).build_deduplicated_audit_logs
        assert_includes logs, revocation_event
      end
    end

    test 'public recovery is neutral during cooldown' do
      first_result = RequestCertificationUpload.new(application: @application, actor: @actor).call
      original = first_result.data.fetch(:medical_provider_secure_request_form)

      result = RequestCertificationUpload.new(
        application: @application,
        actor: @actor,
        resend_of: original,
        public_recovery: true
      ).call

      assert_predicate result, :success?
      assert_predicate original.reload, :status_sent?
      assert_equal 1, MedicalProviderSecureRequestForm.open_certification_upload_for_provider(
        application_id: @application.id,
        provider_email: @application.medical_provider_email
      ).count
    end

    test 'manually revoked certification upload request does not block immediate replacement' do
      first_result = RequestCertificationUpload.new(application: @application, actor: @actor).call
      original = first_result.data.fetch(:medical_provider_secure_request_form)
      original.revoke!(actor: @actor, reason: :manual_revocation)

      result = assert_difference('MedicalProviderSecureRequestForm.count', 1) do
        RequestCertificationUpload.new(application: @application, actor: @actor).call
      end

      assert_predicate result, :success?
      assert_predicate original.reload, :revoked?
      assert_equal 1, MedicalProviderSecureRequestForm.open_certification_upload_for_provider(
        application_id: @application.id,
        provider_email: @application.medical_provider_email
      ).count
    end

    test 'resend targets original provider email snapshot' do
      first_result = RequestCertificationUpload.new(application: @application, actor: @actor).call
      original = first_result.data.fetch(:medical_provider_secure_request_form)
      @application.update!(medical_provider_email: 'updated-provider@example.com')

      travel_to original.sent_at + 2.hours do
        result = RequestCertificationUpload.new(
          application: @application,
          actor: @actor,
          resend_of: original
        ).call

        assert_predicate result, :success?
      end

      replacement = MedicalProviderSecureRequestForm.status_sent.order(:sent_at).last
      assert_equal original.provider_email, replacement.provider_email
      assert_not_equal @application.medical_provider_email, replacement.provider_email
    end

    test 'rejects non-email channels' do
      result = RequestCertificationUpload.new(application: @application, actor: @actor, channel: :fax).call

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.unsupported_channel', locale: @actor.effective_locale),
                   result.message
    end

    test 'deliver_email uses initial request template for non-rejected certifications' do
      delivered_params = nil
      mail = mock('request-certification-mail')
      mail.expects(:deliver_now).returns(true)
      mailer = mock('request-certification-mailer')
      mailer.expects(:request_certification).returns(mail)
      MedicalProviderMailer.expects(:with).with do |params|
        delivered_params = params
        params[:application] == @application &&
          params[:secure_upload_url].match?(/secure_certification_form/) &&
          params[:timestamp].is_a?(String)
      end.returns(mailer)

      result = RequestCertificationUpload.new(
        application: @application,
        actor: @actor,
        deliver_email: true
      ).call

      assert_predicate result, :success?
      assert_equal @application, delivered_params[:application]
    end

    test 'deliver_email uses rejection template for rejected certifications' do
      @application.update!(medical_certification_status: :rejected)
      @application.stubs(:latest_medical_rejection_review).returns(stub(rejection_reason: 'Missing signature'))

      delivered_params = nil
      mail = mock('certification-rejected-mail')
      mail.expects(:deliver_now).returns(true)
      mailer = mock('certification-rejected-mailer')
      mailer.expects(:certification_rejected).returns(mail)
      MedicalProviderMailer.expects(:with).with do |params|
        delivered_params = params
        params[:application] == @application &&
          params[:rejection_reason] == 'Missing signature' &&
          params[:admin] == @actor &&
          params[:secure_upload_url].match?(/secure_certification_form/)
      end.returns(mailer)

      result = RequestCertificationUpload.new(
        application: @application,
        actor: @actor,
        deliver_email: true
      ).call

      assert_predicate result, :success?
      assert_equal 'Missing signature', delivered_params[:rejection_reason]
    end

    test 'delivery failure revokes new secure request and records non-secret failure metadata' do
      mail = mock('failed-request-certification-mail')
      mail.expects(:deliver_now).raises(StandardError, 'smtp timeout https://example.test/secure_certification_form?token=secret')
      mailer = mock('failed-request-certification-mailer')
      mailer.expects(:request_certification).returns(mail)
      MedicalProviderMailer.expects(:with).returns(mailer)

      result = assert_difference('MedicalProviderSecureRequestForm.count', 1) do
        assert_difference("Notification.where(action: 'cert_upload_requested').count", 1) do
          RequestCertificationUpload.new(
            application: @application,
            actor: @actor,
            deliver_email: true
          ).call
        end
      end

      assert_not result.success?
      assert_equal I18n.t('applications.certification_upload.messages.delivery_failed', locale: @actor.effective_locale),
                   result.message
      assert_predicate @application.reload, :medical_certification_status_requested?

      form = result.data.fetch(:medical_provider_secure_request_form)
      notification = Notification.find_by!(notifiable: @application, action: 'cert_upload_requested')
      delivery_error = notification.metadata.fetch('delivery_error')

      assert_predicate form.reload, :revoked?
      assert_equal 0, MedicalProviderSecureRequestForm.open_certification_upload_for_provider(
        application_id: @application.id,
        provider_email: @application.medical_provider_email
      ).count
      assert_equal 'error', notification.delivery_status
      assert_equal form.id, delivery_error.fetch('medical_provider_secure_request_form_id')
      assert_equal form.request_batch_id, delivery_error.fetch('request_batch_id')
      assert_equal 'StandardError', delivery_error.fetch('error_class')
      assert_includes delivery_error.fetch('error_message'), '[REDACTED_URL]'
      assert_not_includes notification.metadata.to_json, 'secret'
      assert_not notification.metadata.key?('secure_upload_url')
    end
  end
end
