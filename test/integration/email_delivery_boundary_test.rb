# frozen_string_literal: true

require 'test_helper'

# Cancellation and outcome boundaries found in pre-PR review, kept as regressions.
class EmailDeliveryBoundaryTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    EmailDelivery::Current.reset
    @admin = create(:admin)
    @system_actor = User.find_by_email(PublicAuditActor::SYSTEM_AUDIT_EMAIL) ||
                    create(:admin, email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
    @user = create(:constituent, communication_preference: 'email')
    load_seeded_email_templates('user_mailer_password_reset', 'evaluator_mailer_evaluation_submission_confirmation',
                                'vendor_notifications_w9_approved', 'medical_provider_request_certification')
    ActionMailer::Base.deliveries.clear
    clear_enqueued_jobs
  end

  teardown do
    EmailDelivery::Current.reset
    Current.reset
  end

  test 'email requested while all email is off does not send after it is turned back on' do
    evaluation = create(:evaluation, constituent: @user)
    clear_enqueued_jobs
    turn_global(false)
    EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.deliver_later
    turn_global(true)

    perform_enqueued_jobs

    assert_empty ActionMailer::Base.deliveries
    assert_equal 'global_disabled', Event.where(action: EmailDelivery::Outcome::SUPPRESSED).order(:id).last.metadata['reason']
  end

  test 'a letter recipient requested while email is off still gets the letter' do
    @user.update!(communication_preference: 'letter')
    evaluation = create(:evaluation, constituent: @user)
    clear_enqueued_jobs
    turn_global(false)
    Letters::TextTemplateToPdfService.any_instance.expects(:queue_for_printing).once

    perform_enqueued_jobs { EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.deliver_later }

    assert_empty ActionMailer::Base.deliveries
  end

  test 'turning a queued template off records a suppression when the job runs' do
    VendorNotificationsMailer.with(vendor: create(:vendor)).w9_approved.deliver_later
    EmailDelivery::ControlWriter.set_template_pair(name: 'vendor_notifications_w9_approved', format: :text, enabled: false,
                                                   actor: @admin, operation_id: 'op-1')

    perform_enqueued_jobs

    assert_empty ActionMailer::Base.deliveries
    assert_equal 1, Event.where(action: EmailDelivery::Outcome::SUPPRESSED).count
  end

  test 'a notification whose email is refused at queueing is recorded as suppressed' do
    vendor = create(:vendor)
    turn_global(false)

    notification = NotificationService.create_and_deliver!(type: :w9_approved, recipient: vendor, actor: @admin,
                                                           notifiable: vendor, channel: :email, audit: true)

    notification.reload
    assert_equal 'suppressed', notification.delivery_status
    assert_equal 'global_disabled', notification.metadata.dig('delivery_suppressed', 'reason')
    assert_equal 'none', notification.metadata['actual_delivery_channel']
    assert_empty enqueued_jobs
  end

  test 'a form loaded before someone turned email off and on again is stale' do
    control = FeatureFlag.find_by!(name: EmailDelivery::GLOBAL_CONTROL)
    version_seen = EmailDelivery::ControlWriter.version_for(control)
    turn_global(false)
    turn_global(true)

    result = EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: false, actor: @admin,
                                              operation_id: 'op-late', expected_version: version_seen)

    assert result.stale?
    assert control.reload.enabled
  end

  test 'a template form loaded before someone turned the pair off and on again is stale' do
    rows = EmailTemplate.where(name: 'user_mailer_password_reset', format: :text).to_a
    version_seen = EmailDelivery::ControlWriter.version_for(rows)
    %w[op-1 op-2].zip([false, true]).each do |operation_id, enabled|
      EmailDelivery::ControlWriter.set_template_pair(name: 'user_mailer_password_reset', format: :text, enabled: enabled,
                                                     actor: @admin, operation_id: operation_id)
    end

    result = EmailDelivery::ControlWriter.set_template_pair(name: 'user_mailer_password_reset', format: :text, enabled: false,
                                                            actor: @admin, operation_id: 'op-late', expected_version: version_seen)

    assert result.stale?
  end

  test 'a certification request prepared before an off and on interval keeps its original authorization' do
    application = create(:application, :in_progress, medical_provider_name: 'Dr. Provider',
                                                     medical_provider_email: 'provider@example.test')
    service_class = Class.new(Applications::RequestCertificationUpload) do
      private

      # Toggle email off and on between preparing the request and sending it.
      def deliver_request_email!(request_form, raw_token)
        EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: false, actor: actor, operation_id: 'mid-off')
        EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: true, actor: actor, operation_id: 'mid-on')
        super
      end
    end

    result = service_class.new(application: application, actor: @admin, deliver_email: true).call

    assert_empty ActionMailer::Base.deliveries
    assert result.data[:delivery_suppressed]
    assert result.data.fetch(:medical_provider_secure_request_form).reload.revoked?
  end

  test 'a certification email stopped after its request was prepared moves certification back from requested' do
    application = create(:application, :in_progress, medical_provider_name: 'Dr. Provider',
                                                     medical_provider_email: 'provider@example.test')
    EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.allowed)
                         .then.returns(EmailDelivery::Decision.suppressed(:global_disabled))

    result = Applications::RequestCertificationUpload.new(application: application, actor: @admin, deliver_email: true).call

    assert result.data[:delivery_suppressed]
    application.reload
    assert application.medical_certification_status_not_requested?
    assert_nil application.medical_certification_requested_at
    assert Event.exists?(action: 'medical_certification_request_suppressed', auditable: application)
  end

  test 'a late certification stop does not undo a status this request did not set' do
    application = create(:application, :in_progress, medical_provider_name: 'Dr. Provider',
                                                     medical_provider_email: 'provider@example.test')
    application.update_columns(medical_certification_status: Application.medical_certification_statuses[:requested],
                               medical_certification_requested_at: 2.days.ago)
    EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.allowed)
                         .then.returns(EmailDelivery::Decision.suppressed(:global_disabled))

    Applications::RequestCertificationUpload.new(application: application, actor: @admin, deliver_email: true).call

    assert application.reload.medical_certification_status_requested?
  end

  test 'a late certification stop keeps a DocuSeal request accepted in the same second' do
    application = create(:application, :in_progress, medical_provider_name: 'Dr. Provider',
                                                     medical_provider_email: 'provider@example.test')
    ::Docuseal.stubs(:create_submission).returns({ 'id' => 'sub-1', 'submitters' => [{ 'id' => 'subm-1' }] })
    EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.allowed)
                         .then.returns(EmailDelivery::Decision.allowed)
                         .then.returns(EmailDelivery::Decision.suppressed(:global_disabled))
    service_class = Class.new(Applications::RequestCertificationUpload) do
      private

      # Another admin sends a DocuSeal request between preparation and the final check.
      def deliver_request_email!(request_form, raw_token)
        result = DocumentSigning::SubmissionService.new(application: application.reload, actor: actor).call
        raise "DocuSeal request failed: #{result.message}" unless result.success?

        super
      end
    end

    travel_to Time.current.change(usec: 100) do
      service_class.new(application: application, actor: @admin, deliver_email: true).call
    end

    application.reload
    assert application.document_signing_status_sent?
    assert application.medical_certification_status_requested?
    assert_not_nil application.medical_certification_requested_at
  end

  test 'a queued notification email suppressed when the worker runs is recorded on the notification' do
    vendor = create(:vendor)
    notification = NotificationService.create_and_deliver!(type: :w9_approved, recipient: vendor, actor: @admin,
                                                           notifiable: vendor, channel: :email, audit: true)
    assert_equal 1, enqueued_jobs.size
    turn_global(false)

    perform_enqueued_jobs

    notification.reload
    assert_empty ActionMailer::Base.deliveries
    assert_equal 'suppressed', notification.delivery_status
    assert_equal 'none', notification.metadata['actual_delivery_channel']
  end

  test 'a preference-routed notification suppressed at the worker records it, and a letter recipient still prints' do
    load_seeded_email_templates('application_notifications_account_created')
    email_user = create(:constituent, communication_preference: 'email')
    letter_user = create(:constituent, communication_preference: 'letter')
    notifications = [email_user, letter_user].map do |user|
      NotificationService.create_and_deliver!(type: :account_created, recipient: user, actor: @admin, notifiable: user,
                                              channel: :email, metadata: { 'temp_password' => 'Temp-Password-1' })
    end
    turn_global(false)
    Letters::TextTemplateToPdfService.any_instance.expects(:queue_for_printing).once

    perform_enqueued_jobs

    assert_empty ActionMailer::Base.deliveries
    assert_equal 'suppressed', notifications.first.reload.delivery_status
    assert_equal 'queued', notifications.last.reload.delivery_status
  end

  test 'feedback on an old attempt does not overwrite a local suppression on its notification' do
    notification = Notification.create!(recipient: @admin, actor: @admin, action: 'medical_certification_requested',
                                        notifiable: create(:application), metadata: {})
    attempt = EmailDeliveryAttempt.create!(notification: notification, correlation_id: SecureRandom.uuid,
                                           recipient_key: EmailDeliveryAttempt.recipient_key('original@example.test'), destination: 'original@example.test',
                                           server_id: 'default', mail_action: 'MedicalProviderMailer#request_certification', attempted_at: Time.current,
                                           provider_message_id: 'pm-1', opened_at: 1.hour.ago)
    notification.mark_delivery_suppressed!('global_disabled')
    fact = EmailDelivery::Feedback.webhook('RecordType' => 'Delivery', 'MessageID' => 'pm-1',
                                           'Recipient' => attempt.destination, 'DeliveredAt' => Time.current.iso8601)
    EmailDelivery::Feedback.apply(fact, server_id: attempt.server_id)
    assert_equal 'suppressed', notification.reload.delivery_status
    assert attempt.reload.opened_at
    assert attempt.delivered_at
  end

  test 'an admin test send refused at queueing reports suppression' do
    template = EmailTemplate.find_by!(name: 'user_mailer_password_reset', format: :text, locale: 'en')
    sign_in_for_integration_test(@admin)
    EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.allowed)
                         .then.returns(EmailDelivery::Decision.suppressed(:global_disabled))

    post send_test_admin_email_template_path(template), headers: default_headers,
                                                        params: { admin_test_email_form: { email: @admin.email, template_id: template.id } }

    assert_redirected_to admin_email_template_path(template)
    assert_equal 'Test email not sent: all email is turned off.', flash[:alert]
    assert_empty ActionMailer::Base.deliveries
  end

  test 'a suppressed notification without a provider message id shows its status' do
    notification = Notification.create!(recipient: @admin, actor: @admin, action: 'medical_certification_requested',
                                        notifiable: create(:application), metadata: {})
    notification.mark_delivery_suppressed!('global_disabled')

    badge = ApplicationController.helpers.delivery_status_badge(notification)

    assert_includes badge, I18n.t('delivery_visibility.statuses.suppressed')
    assert_includes DeliveryStatusPresenter.new(notification).description, 'switched off'
  end

  private

  def turn_global(value)
    EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: value, actor: @admin,
                                     operation_id: SecureRandom.uuid)
  end
end
