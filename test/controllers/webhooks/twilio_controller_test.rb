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
  end
end
