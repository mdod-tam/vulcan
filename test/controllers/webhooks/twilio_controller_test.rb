# frozen_string_literal: true

require 'test_helper'

module Webhooks
  class TwilioControllerTest < ActionDispatch::IntegrationTest
    setup do
      @application = create(:application)
      @notification = create(
        :notification,
        recipient: @application.user,
        actor: create(:admin),
        notifiable: @application,
        action: 'medical_certification_rejected',
        metadata: { 'fax_sid' => 'FX_TEST_123', 'reason' => 'Missing signature' }
      )
    end

    test 'fax_status updates matching notification metadata and delivery status' do
      post webhooks_twilio_fax_status_path, params: {
        FaxSid: 'FX_TEST_123',
        Status: 'delivered'
      }

      assert_response :ok
      @notification.reload
      assert_equal 'delivered', @notification.delivery_status
      assert_equal 'delivered', @notification.metadata['fax_status']
      assert_equal 'delivered', @notification.metadata['fax_status_details']
      assert @notification.metadata['fax_status_updated_at'].present?
    end

    test 'fax_status returns success false when fax sid is not found' do
      post webhooks_twilio_fax_status_path, params: {
        FaxSid: 'FX_UNKNOWN',
        Status: 'delivered'
      }

      assert_response :ok
      body = response.parsed_body
      assert_equal false, body['success']
      assert_equal 'Notification not found', body['error']
    end

    test 'fax_status marks failed fax as error and queues email fallback once' do
      mail = mock('mail')
      mail.stubs(:message_id).returns('MSG-FALLBACK-1')
      mail.expects(:deliver_later).once

      mailer_proxy = mock('mailer_proxy')
      mailer_proxy.stubs(:certification_rejected).returns(mail)
      MedicalProviderMailer.expects(:with).once.returns(mailer_proxy)

      2.times do
        post webhooks_twilio_fax_status_path, params: {
          FaxSid: 'FX_TEST_123',
          Status: 'failed'
        }
        assert_response :ok
      end

      @notification.reload
      assert_equal 'error', @notification.delivery_status
      assert_equal 'failed', @notification.metadata['fax_status']
      assert_equal 'failed', @notification.metadata['fax_status_details']
      assert_equal 'MSG-FALLBACK-1', @notification.metadata['email_fallback_message_id']
      assert @notification.metadata['email_fallback_sent_at'].present?
      assert_equal 'queued', @notification.metadata['email_fallback_status']
      assert_equal 'failed', @notification.metadata['email_fallback_trigger_status']
    end
  end
end
