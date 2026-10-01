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

    test 'rejected callbacks redact bodies credentials and query values before request logging' do
      private_fields = { TextBody: 'private-message-body', Description: 'private-provider-description',
                         From: 'private-sender@example.test', NewDiagnostic: 'private-new-diagnostic' }
      headers = { 'Authorization' => ActionController::HttpAuthentication::Basic.encode_credentials('private-username', 'private-password') }
      log = capture_webhook_logs do
        post "#{webhooks_email_events_path}.json?Description=private-query-description",
             params: @payload.merge(private_fields), headers: headers, as: :json
      end

      assert_response :unauthorized
      assert_nil @attempt.reload.delivered_at
      assert_includes log, '[FILTERED]'
      private_fields.each_value { |value| assert_not_includes log, value }
      assert_not_includes log, 'private-query-description'
      assert_not_includes log, headers['Authorization']
      assert_equal '[FILTERED]', request.filtered_env['HTTP_AUTHORIZATION']
      assert_equal '[FILTERED]', request.filtered_parameters['NewDiagnostic']
    end

    test 'accepted callbacks do not log hostile type metadata through webhook instrumentation' do
      log = capture_webhook_logs do
        post webhooks_email_events_path, params: @payload.merge(type: 'private-webhook-type'), headers: @headers, as: :json
      end

      assert_response :ok
      assert @attempt.reload.delivered_at
      assert_includes log, 'Webhook received: Webhooks::EmailEventsController#create'
      assert_includes log, 'Type=[FILTERED]'
      assert_not_includes log, 'private-webhook-type'
    end

    test 'malformed callback bodies remain private even when debug logging is enabled' do
      log = capture_webhook_logs do
        Rails.logger.level = :debug
        post webhooks_email_events_path,
             params: 'private-malformed-body',
             headers: @headers.merge('CONTENT_TYPE' => 'application/json'),
             env: { 'action_dispatch.log_rescued_responses' => true }
      end

      assert_response :bad_request
      assert_equal 'Bad Request', response.body
      assert_not_includes log, 'private-malformed-body'
      assert_nil @attempt.reload.delivered_at
    end

    test 'invalid callback content types return a private bad request before framework error logging' do
      log = capture_webhook_logs do
        Rails.logger.level = :debug
        post webhooks_email_events_path, params: '{}', headers: @headers.merge('CONTENT_TYPE' => 'private-invalid-content-type')
      end

      assert_response :bad_request
      assert_equal 'Bad Request', response.body
      assert_not_includes log, 'private-invalid-content-type'
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

    private

    def capture_webhook_logs(&)
      original_logger = ActionController::Base.logger
      original_request_logger = Rails.application.env_config['action_dispatch.logger']
      capture_rails_logs do
        ActionController::Base.logger = Rails.logger
        Rails.application.env_config['action_dispatch.logger'] = Rails.logger
        yield
      end
    ensure
      ActionController::Base.logger = original_logger
      Rails.application.env_config['action_dispatch.logger'] = original_request_logger
    end
  end
end
