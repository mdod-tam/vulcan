# frozen_string_literal: true

require 'test_helper'

module Webhooks
  class TwilioControllerTest < ActionDispatch::IntegrationTest
    setup do
      @application = create(:application, medical_provider_email: 'doctor@example.com')
      @admin = create(:admin)
      ensure_system_audit_actor!
      @notification = create(:notification, recipient: @application.user, actor: @admin, notifiable: @application,
                                            action: 'medical_certification_rejected',
                                            metadata: { 'fax_sid' => 'FX_TEST_123', 'rejection_reason' => 'Missing signature',
                                                        'provider_delivery_contexts' => {
                                                          'email' => EmailDelivery::Policy.capture(mail_action: MedicalProviderNotifier::EMAIL_ACTION)
                                                        } })
    end

    test 'provider history survives All off and out of order callbacks' do
      toggle(false)
      callback('delivered')
      callback('sending')
      callback('failed')
      assert_equal 'delivered', @notification.reload.delivery_status
      assert_equal 'delivered', @notification.metadata['fax_status_details']
      assert_nil @notification.metadata['email_fallback']
    end

    test 'unknown sid is acknowledged without delivery' do
      post webhooks_twilio_fax_status_path, params: { FaxSid: 'FX_UNKNOWN', Status: 'delivered' }
      assert_response :ok
      assert_equal false, response.parsed_body['success']
    end

    test 'a duplicate failure queues one fallback with original authorization' do
      assert_enqueued_jobs 1, only: EmailDelivery::MailDeliveryJob do
        2.times { callback('failed') }
      end
      assert_equal 'error', @notification.reload.delivery_status
      assert_equal 'queued', @notification.metadata.dig('email_fallback', 'status')
    end

    test 'off on interval suppresses fallback without overwriting fax history' do
      toggle(false)
      toggle(true)
      assert_no_enqueued_jobs only: EmailDelivery::MailDeliveryJob do
        callback('failed')
      end
      assert_equal 'error', @notification.reload.delivery_status
      assert_equal 'suppressed', @notification.metadata.dig('email_fallback', 'status')
      assert_equal 'pending_canceled', @notification.metadata.dig('email_fallback', 'reason')
    end

    test 'legacy callback cannot acquire new authorization' do
      @notification.update!(metadata: @notification.metadata.except('provider_delivery_contexts'))
      assert_no_enqueued_jobs only: EmailDelivery::MailDeliveryJob do
        callback('failed')
      end
      assert_equal 'legacy_context_missing', @notification.reload.metadata.dig('email_fallback', 'reason')
    end

    private

    def callback(status)
      post webhooks_twilio_fax_status_path, params: { FaxSid: 'FX_TEST_123', Status: status }
      assert_response :ok
    end

    def toggle(enabled)
      EmailDelivery::ControlWriter.set(name: EmailDelivery::ALL_CONTROL, enabled: enabled, actor: @admin, operation_id: SecureRandom.uuid)
    end
  end
end
