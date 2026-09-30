# frozen_string_literal: true

require 'test_helper'

class EmailDeliveryFeedbackTest < ActiveSupport::TestCase
  teardown { ENV['POSTMARK_SERVER_ID'] = @previous_server_id }

  setup do
    @previous_server_id = ENV.fetch('POSTMARK_SERVER_ID', nil)
    ENV['POSTMARK_SERVER_ID'] = '23'
    ensure_system_audit_actor!
    @attempt = EmailDeliveryAttempt.create!(correlation_id: SecureRandom.uuid, recipient_key: EmailDeliveryAttempt.recipient_key('original@example.test'),
                                            destination: 'original@example.test', server_id: '23', mail_action: 'UserMailer#password_reset',
                                            attempted_at: Time.current, provider_message_id: 'provider-1', state: 'accepted')
  end

  test 'distinct and out of order events preserve adverse facts with one durable bounce audit' do
    deliver_time = 3.minutes.ago.change(usec: 0)
    apply('Delivery', 'DeliveredAt' => deliver_time.iso8601)
    apply('Bounce', 'ID' => 42, 'Type' => 'HardBounce')
    travel 10.minutes do
      apply('Bounce', 'ID' => 42, 'Type' => 'HardBounce')
      apply('Open', 'ReceivedAt' => 1.minute.ago.iso8601)
      apply('SpamComplaint', 'ID' => 43)
      apply('Delivery', 'DeliveredAt' => deliver_time.iso8601)
    end
    @attempt.reload
    assert_equal deliver_time, @attempt.delivered_at
    assert @attempt.opened_at
    assert @attempt.bounced_at
    assert @attempt.complained_at
    assert_equal 4, @attempt.email_delivery_receipts.count
    assert_equal 1, Event.where(action: 'email_bounced').count
    assert_equal 'HardBounce', @attempt.bounce_category
    assert_not_includes @attempt.attributes.to_json, 'secret-token'
  end

  test 'early callback uses correlation and exact recipient rather than current contact' do
    @attempt.update!(provider_message_id: nil, state: 'unknown')
    apply('Delivery', 'Metadata' => { 'delivery_attempt' => @attempt.correlation_id })
    assert_equal 'provider-1', @attempt.reload.provider_message_id
    assert @attempt.delivered_at
    assert_equal :unmatched, apply('Bounce', 'Email' => 'replacement@example.test', 'Recipient' => 'replacement@example.test')
    assert_nil @attempt.reload.bounced_at
  end

  test 'one provider message can have independent recipient feedback' do
    second = @attempt.dup
    second.assign_attributes(destination: 'second@example.test', recipient_key: EmailDeliveryAttempt.recipient_key('second@example.test'))
    second.save!
    apply('Bounce', 'Email' => 'second@example.test', 'Recipient' => 'second@example.test', 'ID' => 22)
    assert_nil @attempt.reload.bounced_at
    assert second.reload.bounced_at
  end

  test 'missing actor does not lose feedback or change any users and replay can repair breadcrumb' do
    PublicAuditActor.stubs(:system_audit_actor).returns(nil)
    roles = User.pluck(:id, :type)
    apply('Bounce', 'ID' => 42)
    assert @attempt.reload.bounced_at
    assert_nil @attempt.bounce_event_id
    assert_equal roles, User.pluck(:id, :type)
    PublicAuditActor.unstub(:system_audit_actor)
    apply('Bounce', 'ID' => 42)
    assert @attempt.reload.bounce_event_id
    assert_equal 1, @attempt.email_delivery_receipts.count
  end

  test 'real SDK JSON formatting feeds the updater without raw diagnostics' do
    transport = mock
    response = stub(code: '200', body: {
      MessageID: 'provider-1', Status: 'Sent', TextBody: 'secret-token',
      MessageEvents: [{ Type: 'Delivered', Recipient: @attempt.destination, ReceivedAt: Time.current.iso8601,
                        Details: { DeliveryMessage: 'secret-token' } }]
    }.to_json)
    transport.expects(:get).returns(response)
    Postmark::HttpClient.any_instance.stubs(:build_http).returns(transport)
    client = Postmark::ApiClient.new('offline-test')
    data = client.get_message('provider-1')
    assert_equal 'Sent', data[:status]
    assert_nil data['Status']
    assert_equal 'Delivered', data[:message_events].first['Type']
    assert_respond_to client, :get_opens_by_message_id
    assert_not_respond_to client, :get_message_opens
    EmailDelivery::Feedback.sdk(data, @attempt).each { |fact| EmailDelivery::Feedback.apply(fact) }
    assert @attempt.reload.delivered_at
    assert_not_includes @attempt.attributes.to_json, 'secret-token'
  end

  private

  def apply(kind, fields = {})
    payload = { 'RecordType' => kind, 'MessageID' => 'provider-1', 'Recipient' => @attempt.destination,
                'Email' => @attempt.destination, 'BouncedAt' => Time.current.iso8601, 'DeliveredAt' => Time.current.iso8601,
                'Details' => 'secret-token', 'Content' => 'secret-token' }.merge(fields)
    EmailDelivery::Feedback.apply(EmailDelivery::Feedback.webhook(payload))
  end
end
