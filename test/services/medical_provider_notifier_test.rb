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
                          metadata: { 'reason' => 'Missing signature' })

    notifier = MedicalProviderNotifier.new(@application)
    notifier.stubs(:notify_by_email).returns(
      { success: true, method: 'email', message_id: 'MSG-123' }
    )
    notifier.expects(:notify_by_fax).never

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
    assert_equal %w[email fax], notification.metadata['notification_methods']
  end

  test 'updates specified rejection notification metadata on successful fax delivery' do
    targeted_notification = create(:notification,
                                   recipient: @application.user,
                                   actor: @admin,
                                   notifiable: @application,
                                   action: 'medical_certification_rejected',
                                   metadata: { 'reason' => 'Missing signature' })

    newer_notification = create(:notification,
                                recipient: @application.user,
                                actor: @admin,
                                notifiable: @application,
                                action: 'medical_certification_rejected',
                                metadata: { 'reason' => 'Different reason' })

    notifier = MedicalProviderNotifier.new(@application)
    notifier.stubs(:notify_by_email).returns(
      { success: false, method: 'email', error: 'smtp timeout' }
    )
    notifier.stubs(:notify_by_fax).returns(
      { success: true, method: 'fax', fax_sid: 'FX123', blob_id: 42 }
    )

    result = notifier.send_certification_rejection_notice(
      rejection_reason: 'Missing signature',
      admin: @admin,
      notification_id: targeted_notification.id
    )

    assert_equal true, result
    targeted_notification.reload
    newer_notification.reload

    assert_equal 'fax', targeted_notification.metadata['delivery_method']
    assert_equal 'FX123', targeted_notification.metadata['fax_sid']
    assert_equal 42, targeted_notification.metadata['blob_id']
    assert_equal %w[email fax], targeted_notification.metadata['notification_methods']
    assert_nil newer_notification.metadata['fax_sid']
  end

  test 'prefers document signing when application previously used that channel' do
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
                          metadata: { 'reason' => 'Missing signature' })

    notifier = MedicalProviderNotifier.new(@application)
    notifier.stubs(:notify_by_document_signing).returns(
      {
        success: true,
        method: 'document_signing',
        document_signing_submission_id: 'sub_123',
        document_signing_service: 'docuseal'
      }
    )
    notifier.expects(:notify_by_email).never
    notifier.expects(:notify_by_fax).never

    result = notifier.send_certification_rejection_notice(
      rejection_reason: 'Missing signature',
      admin: @admin,
      notification_id: notification.id
    )

    assert_equal true, result
    notification.reload
    assert_equal 'document_signing', notification.metadata['delivery_method']
    assert_equal 'sub_123', notification.metadata['document_signing_submission_id']
    assert_equal 'docuseal', notification.metadata['document_signing_service']
    assert_equal %w[document_signing email fax], notification.metadata['notification_methods']
  end

  test 'falls back to email when document signing fails' do
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
                          metadata: { 'reason' => 'Missing signature' })

    notifier = MedicalProviderNotifier.new(@application)
    notifier.stubs(:notify_by_document_signing).returns(
      { success: false, method: 'document_signing', error: 'provider unavailable' }
    )
    notifier.stubs(:notify_by_email).returns(
      { success: true, method: 'email', message_id: 'MSG-987' }
    )
    notifier.expects(:notify_by_fax).never

    result = notifier.send_certification_rejection_notice(
      rejection_reason: 'Missing signature',
      admin: @admin,
      notification_id: notification.id
    )

    assert_equal true, result
    notification.reload
    assert_equal 'email', notification.metadata['delivery_method']
    assert_equal 'MSG-987', notification.metadata['message_id']
    assert_equal 'document_signing', notification.metadata['email_fallback_from']
  end

  test 'builds fax status callback URL using webhooks helper' do
    notifier = MedicalProviderNotifier.new(@application)
    url_options = Rails.application.config.action_mailer.default_url_options
    expected = Rails.application.routes.url_helpers.webhooks_twilio_fax_status_url(
      host: url_options[:host],
      protocol: url_options[:protocol] || 'https'
    )

    assert_equal expected, notifier.send(:fax_options)[:status_callback]
  end
end
