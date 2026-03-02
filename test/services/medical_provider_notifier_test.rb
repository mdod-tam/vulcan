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

  test 'returns false without raising when fax is unavailable' do
    @application.update!(medical_provider_fax: nil)

    notifier = MedicalProviderNotifier.new(@application)

    result = nil
    assert_nothing_raised do
      result = notifier.send_certification_rejection_notice(
        rejection_reason: 'Missing signature',
        admin: @admin
      )
    end

    assert_equal false, result
  end

  test 'updates latest rejection notification metadata on successful fax delivery' do
    notification = create(:notification,
                          recipient: @application.user,
                          actor: @admin,
                          notifiable: @application,
                          action: 'medical_certification_rejected',
                          metadata: { 'reason' => 'Missing signature' })

    notifier = MedicalProviderNotifier.new(@application)
    notifier.stubs(:try_fax_delivery).returns(
      { success: true, method: 'fax', fax_sid: 'FX123', blob_id: 42 }
    )

    result = notifier.send_certification_rejection_notice(
      rejection_reason: 'Missing signature',
      admin: @admin
    )

    assert_equal true, result
    notification.reload
    assert_equal 'fax', notification.metadata['delivery_method']
    assert_equal 'FX123', notification.metadata['fax_sid']
    assert_equal 42, notification.metadata['blob_id']
    assert_equal %w[fax email], notification.metadata['notification_methods']
  end

  test 'builds fax status callback URL using webhooks helper' do
    notifier = MedicalProviderNotifier.new(@application)
    host = Rails.application.config.action_mailer.default_url_options[:host]
    expected = Rails.application.routes.url_helpers.webhooks_twilio_fax_status_url(host: host)

    assert_equal expected, notifier.send(:fax_options)[:status_callback]
  end
end
