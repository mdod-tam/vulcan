# frozen_string_literal: true

require 'test_helper'

class MedicalProviderNotifierTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @constituent = create(:constituent)
    @application = create(:application,
                          user: @constituent,
                          medical_provider_name: 'Dr. Provider',
                          medical_provider_email: 'provider@example.com',
                          medical_provider_fax: '+14105551212')

    AuditEventService.stubs(:log)
  end

  test 'prefers email over fax when document signing has not been used' do
    @application.update!(document_signing_request_count: 0, document_signing_status: :not_sent)

    notification = create(:notification,
                          recipient: @application.user,
                          actor: @admin,
                          notifiable: @application,
                          action: 'medical_certification_rejected',
                          metadata: { 'rejection_reason' => 'Missing signature' })

    notifier = MedicalProviderNotifier.new(@application)
    notifier.stubs(:notify_by_email).returns(
      { success: true, method: 'email', message_id: 'MSG-123' }
    )

    result = nil
    assert_nothing_raised do
      result = notifier.send_certification_rejection_notice(
        rejection_reason: 'Missing signature',
        admin: @admin,
        notification_id: notification.id
      )
    end

    assert_equal true, result
    notification.reload
    assert_equal 'email', notification.metadata['delivery_method']
    assert_equal 'MSG-123', notification.metadata['message_id']
    assert_equal %w[email], notification.metadata['notification_methods']
  end

  test 'uses email for rejection notice when application previously used document signing' do
    @application.update!(
      document_signing_request_count: 1,
      document_signing_status: :sent,
      document_signing_service: 'docuseal'
    )

    notification = create(:notification,
                          recipient: @application.user,
                          actor: @admin,
                          notifiable: @application,
                          action: 'medical_certification_rejected',
                          metadata: { 'rejection_reason' => 'Missing signature' })

    notifier = MedicalProviderNotifier.new(@application)
    DocumentSigning::SubmissionService.expects(:new).never
    notifier.stubs(:notify_by_email).returns(
      { success: true, method: 'email', message_id: 'MSG-456' }
    )

    result = notifier.send_certification_rejection_notice(
      rejection_reason: 'Missing signature',
      admin: @admin,
      notification_id: notification.id
    )

    assert_equal true, result
    notification.reload
    assert_equal 'email', notification.metadata['delivery_method']
    assert_equal 'MSG-456', notification.metadata['message_id']
    assert_equal %w[email], notification.metadata['notification_methods']
  end

  test 'passes secure upload url to rejection email and delivers synchronously' do
    notifier = MedicalProviderNotifier.new(@application)
    mail = mock('certification_rejected_mail')
    mail.expects(:deliver_now).returns(true)
    mail.expects(:message_id).returns('MSG-SECURE')
    mail.expects(:deliver_later).never
    mailer_proxy = mock('medical_provider_mailer_proxy')
    mailer_proxy.expects(:certification_rejected).returns(mail)

    MedicalProviderMailer.expects(:with).with(
      application: @application,
      rejection_reason: 'Missing signature',
      admin: @admin,
      secure_upload_url: 'https://example.test/secure_certification_form?token=abc'
    ).returns(mailer_proxy)

    result = notifier.send_certification_rejection_notice(rejection_reason: 'Missing signature', admin: @admin,
                                                          secure_upload_url: 'https://example.test/secure_certification_form?token=abc')
    assert_equal true, result
  end

  test 'redacts secure upload urls from email errors and notification metadata' do
    @application.update!(medical_provider_fax: nil)
    notification = create(:notification,
                          recipient: @application.user,
                          actor: @admin,
                          notifiable: @application,
                          action: 'medical_certification_rejected',
                          metadata: { 'rejection_reason' => 'Missing signature' })
    secure_upload_url = 'https://example.test/secure_certification_form?token=raw-secret-token'
    raw_error = "SMTP rejected message containing #{secure_upload_url}"
    mail = mock('certification_rejected_mail')
    mail.expects(:deliver_now).raises(StandardError, raw_error)
    mailer_proxy = mock('medical_provider_mailer_proxy')
    mailer_proxy.expects(:certification_rejected).returns(mail)
    MedicalProviderMailer.expects(:with).with(
      application: @application,
      rejection_reason: 'Missing signature',
      admin: @admin,
      secure_upload_url: secure_upload_url
    ).returns(mailer_proxy)

    original_logger = Rails.logger
    log_output = StringIO.new

    begin
      Rails.logger = ActiveSupport::Logger.new(log_output)
      result = MedicalProviderNotifier.new(@application).send_certification_rejection_notice(
        rejection_reason: 'Missing signature',
        admin: @admin,
        notification_id: notification.id,
        secure_upload_url: secure_upload_url
      )
    ensure
      Rails.logger = original_logger
    end

    assert_equal false, result
    notification.reload
    assert_equal 'SMTP rejected message containing [REDACTED_URL]',
                 notification.metadata.fetch('provider_notification_error')
    assert_includes log_output.string, '[REDACTED_URL]'
    assert_not_includes log_output.string, secure_upload_url
    assert_not_includes log_output.string, 'raw-secret-token'
  end

  test 'email failure is not silently routed to the unavailable fax provider' do
    notification = create(:notification, recipient: @application.user, actor: @admin, notifiable: @application,
                                         action: 'medical_certification_rejected')
    notifier = MedicalProviderNotifier.new(@application)
    notifier.stubs(:notify_by_email).returns(success: false, method: 'email', error: 'smtp timeout')
    FaxService.any_instance.expects(:send_fax).never

    assert_equal false, notifier.send_certification_rejection_notice(rejection_reason: 'Missing signature', admin: @admin,
                                                                     notification_id: notification.id)
    assert_nil notification.reload.metadata['fax_sid']
    assert_equal 'smtp timeout', notification.metadata['provider_notification_error']
  end

  test 'fax-only provider gets an explicit unavailable result' do
    @application.update_column(:medical_provider_email, nil)
    notification = create(:notification, recipient: @application.user, actor: @admin, notifiable: @application,
                                         action: 'medical_certification_rejected')
    assert_equal false, MedicalProviderNotifier.new(@application).send_certification_rejection_notice(
      rejection_reason: 'Missing signature', admin: @admin, notification_id: notification.id
    )
    assert_equal FaxService::UNAVAILABLE_MESSAGE, notification.reload.metadata['provider_notification_error']
  end
end
