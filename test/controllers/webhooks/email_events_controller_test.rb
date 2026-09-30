# frozen_string_literal: true

require 'test_helper'

module Webhooks
  class EmailEventsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @old_env = ENV.to_h.slice('POSTMARK_SERVER_ID', 'POSTMARK_WEBHOOK_USERNAME', 'POSTMARK_WEBHOOK_PASSWORD')
      ENV['POSTMARK_SERVER_ID'] = '23'
      ENV['POSTMARK_WEBHOOK_USERNAME'] = 'offline-webhook'
      ENV['POSTMARK_WEBHOOK_PASSWORD'] = 'offline-secret'
      @headers = { 'Authorization' => ActionController::HttpAuthentication::Basic.encode_credentials('offline-webhook', 'offline-secret') }
      @attempt = EmailDeliveryAttempt.create!(correlation_id: SecureRandom.uuid, recipient_key: EmailDeliveryAttempt.recipient_key('provider@example.test'),
                                              destination: 'provider@example.test', server_id: '23', mail_action: 'MedicalProviderMailer#request_certification',
                                              attempted_at: Time.current)
      @payload = { RecordType: 'Delivery', MessageID: 'provider-123', ServerID: 23, Recipient: @attempt.destination,
                   DeliveredAt: Time.current.iso8601, Metadata: { delivery_attempt: @attempt.correlation_id } }
    end

    teardown do
      %w[POSTMARK_SERVER_ID POSTMARK_WEBHOOK_USERNAME POSTMARK_WEBHOOK_PASSWORD].each { |key| ENV[key] = @old_env[key] }
    end

    test 'real endpoint authenticates supported payload and binds early callback' do
      post webhooks_email_events_path, params: @payload, headers: @headers, as: :json
      assert_response :ok
      assert @attempt.reload.delivered_at
      assert_equal 'provider-123', @attempt.provider_message_id
    end

    test 'missing or invalid credentials cannot mutate delivery' do
      post webhooks_email_events_path, params: @payload, as: :json
      assert_response :unauthorized
      post webhooks_email_events_path, params: @payload, headers: { 'X-Webhook-Signature' => 'test_webhook_secret' }, as: :json
      assert_response :unauthorized
      headers = { 'Authorization' => ActionController::HttpAuthentication::Basic.encode_credentials('offline-webhook', 'wrong') }
      post webhooks_email_events_path, params: @payload, headers: headers, as: :json
      assert_response :unauthorized
      assert_nil @attempt.reload.delivered_at
    end

    test 'missing or blank server configuration cannot mutate delivery' do
      [nil, '', ' '].each do |server_id|
        ENV['POSTMARK_SERVER_ID'] = server_id
        assert_no_difference 'EmailDeliveryReceipt.count' do
          post webhooks_email_events_path, params: @payload, headers: @headers, as: :json
        end
        assert_response :unauthorized
        assert_nil @attempt.reload.delivered_at
        assert_nil @attempt.provider_message_id
      end
    end

    test 'missing configuration fails closed and wrong server or malformed payload is rejected' do
      post webhooks_email_events_path, params: @payload.merge(ServerID: 99), headers: @headers, as: :json
      assert_response :unprocessable_content
      post webhooks_email_events_path, params: @payload.merge(Metadata: ['invalid']), headers: @headers, as: :json
      assert_response :unprocessable_content
      post webhooks_email_events_path, params: @payload.merge(DeliveredAt: 'not a timestamp'), headers: @headers, as: :json
      assert_response :unprocessable_content
      ENV.delete('POSTMARK_WEBHOOK_PASSWORD')
      post webhooks_email_events_path, params: @payload, headers: @headers, as: :json
      assert_response :unauthorized
      assert_nil @attempt.reload.delivered_at
    end
  end
end
