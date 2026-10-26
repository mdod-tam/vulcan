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

    test 'callback exceptions keep private provider details out of logs and JSON and allow retry' do
      sentinel = 'private-fax-sentinel doctor@example.test token=secret-provider-token'
      log = StringIO.new
      notifier = MedicalProviderNotifier.new(@application)
      original_metadata = @notification.metadata.deep_dup

      assert_no_difference ['Event.count', 'Notification.count'] do
        Rails.stub(:logger, ActiveSupport::Logger.new(log)) do
          MedicalProviderNotifier.stub(:new, notifier) do
            notifier.stub(:receive_fax_status, ->(*) { raise StandardError, sentinel }) do
              post webhooks_twilio_fax_status_path, params: { FaxSid: 'FX_TEST_123', Status: 'delivered' }
            end
          end
        end
      end

      assert_response :internal_server_error
      assert_equal({ 'success' => false, 'error' => 'Callback could not be processed' }, response.parsed_body)
      assert_not_includes response.body, sentinel
      assert_not_includes log.string, sentinel
      assert_includes log.string, 'Error handling fax status update: StandardError'
      assert_equal original_metadata, @notification.reload.metadata

      callback('delivered')
      assert_equal 'delivered', @notification.reload.delivery_status
    end

    test 'invalid signature diagnostics omit query credentials' do
      sentinel = 'private-fax-signature-token'
      log = StringIO.new
      validator = mock('signature validator')
      validator.expects(:validate).returns(false)
      MedicalProviderNotifier.expects(:new).never

      assert_no_difference ['Event.count', 'Notification.count'] do
        Rails.stub(:logger, ActiveSupport::Logger.new(log)) do
          Rails.env.stub(:production?, true) do
            Twilio::Security::RequestValidator.stub(:new, validator) do
              post webhooks_twilio_fax_status_path(token: sentinel),
                   params: { FaxSid: 'FX_TEST_123', Status: 'delivered' }, headers: { 'X-Twilio-Signature' => 'invalid' }
            end
          end
        end
      end

      assert_response :forbidden
      assert_equal({ 'error' => 'Invalid signature' }, response.parsed_body)
      assert_includes log.string, 'Invalid Twilio signature for fax status callback'
      assert_not_includes log.string, sentinel
      assert_not_includes response.body, sentinel
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
