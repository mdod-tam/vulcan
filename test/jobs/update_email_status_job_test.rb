# frozen_string_literal: true

require 'test_helper'

class UpdateEmailStatusJobTest < ActiveJob::TestCase
  teardown { ENV['POSTMARK_SERVER_ID'] = @previous_server_id }

  setup do
    @previous_server_id = ENV.fetch('POSTMARK_SERVER_ID', nil)
    ENV['POSTMARK_SERVER_ID'] = '23'
    @notification = Notification.create!(recipient: create(:constituent), notifiable: create(:application), action: 'medical_certification_requested', message_id: 'legacy-rfc-id')
    @attempt = EmailDeliveryAttempt.create!(notification: @notification, correlation_id: SecureRandom.uuid,
                                            recipient_key: EmailDeliveryAttempt.recipient_key('provider@example.test'), destination: 'provider@example.test',
                                            server_id: '23', mail_action: 'MedicalProviderMailer#request_certification',
                                            attempted_at: Time.current, provider_message_id: 'provider-id', state: 'accepted')
    @client = mock
    Postmark::ApiClient.stubs(:new).returns(@client)
    Rails.application.credentials.stubs(:postmark_api_token).returns('offline-test')
  end

  test 'refresh failure preserves known facts and consumes finite budget' do
    @client.expects(:get_message).with('provider-id').raises(StandardError, 'secret diagnostic')
    UpdateEmailStatusJob.perform_now(@notification.id)
    assert_equal 'accepted', @attempt.reload.state
    assert @attempt.check_failed_at
    assert_equal 1, @attempt.check_count
    assert_not @attempt.check_available?
    assert_nil @notification.reload.delivery_status
  end

  test 'confirmed delivery stops polling without waiting for open' do
    @attempt.update!(delivered_at: Time.current)
    @client.expects(:get_message).never
    UpdateEmailStatusJob.perform_now(@notification.id)
    assert @attempt.reload.delivered_at
    assert_equal 0, @attempt.check_count
  end

  test 'age and count cap polling and legacy IDs never create attempts' do
    @attempt.update!(check_count: EmailDeliveryAttempt::MAX_CHECKS)
    @client.expects(:get_message).never
    UpdateEmailStatusJob.perform_now(@notification.id)
    @attempt.update!(check_count: 0, attempted_at: 8.days.ago)
    UpdateEmailStatusJob.perform_now(@notification.id)
    @attempt.destroy!
    assert_no_difference 'EmailDeliveryAttempt.count' do
      UpdateEmailStatusJob.perform_now(@notification.id)
    end
  end
end
