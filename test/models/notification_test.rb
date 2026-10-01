# frozen_string_literal: true

require 'test_helper'

class NotificationTest < ActiveSupport::TestCase
  setup do
    @recipient = create(:constituent)
    @application = create(:application, user: @recipient)
    @notification = Notification.create!(recipient: @recipient, notifiable: @application, action: 'proof_submitted',
                                         metadata: { 'workflow' => 'preserved' })
  end

  test 'delivery failure preserves metadata and normalizes safe request context' do
    @notification.mark_delivery_failed!(StandardError.new('secret transport diagnostic'),
                                        details: { secure_request_form_id: 12, request: { batch_id: 'batch' },
                                                   message: 'secret override', error_class: 'override' })

    @notification.reload
    assert_equal 'error', @notification.delivery_status
    assert_equal 'preserved', @notification.metadata['workflow']
    assert_equal 12, @notification.metadata.dig('delivery_error', 'secure_request_form_id')
    assert_equal 'batch', @notification.metadata.dig('delivery_error', 'request', 'batch_id')
    assert_equal 'Email could not be sent.', @notification.email_error_message
    assert_equal 'StandardError', @notification.metadata.dig('delivery_error', 'error_class')
    assert_not_includes @notification.metadata.to_json, 'secret'
  end

  %i[suppressed configuration_error].each do |outcome|
    test "a stale failure writer preserves a #{outcome} decision" do
      stale = Notification.find(@notification.id)
      @notification.mark_delivery_not_sent!(EmailDelivery::Decision.public_send(outcome, :test_reason))
      expected = @notification.reload.attributes.slice('delivery_status', 'metadata')

      stale.mark_delivery_failed!(StandardError.new('later error'))
      stale.mark_delivery_enqueue_failed!(StandardError.new('later queue error'))

      assert_equal expected, @notification.reload.attributes.slice('delivery_status', 'metadata')
    end
  end

  %w[accepted failed unknown].each do |state|
    test "pre-handoff writers preserve a linked #{state} attempt" do
      @notification.record_delivery_handoff!(channel: :email)
      stale = Notification.find(@notification.id)
      attempt = EmailDeliveryAttempt.create!(notification: @notification, correlation_id: SecureRandom.uuid,
                                             recipient_key: EmailDeliveryAttempt.recipient_key(@recipient.email),
                                             destination: @recipient.email, server_id: '23',
                                             mail_action: 'UserMailer#password_reset', attempted_at: Time.current, state: state)
      expected = @notification.reload.attributes.slice('delivery_status', 'metadata')

      stale.mark_delivery_failed!(StandardError.new('later error'))
      stale.mark_delivery_enqueue_failed!(StandardError.new('later queue error'))

      assert_equal expected, @notification.reload.attributes.slice('delivery_status', 'metadata')
      assert_equal state, attempt.reload.state
    end
  end
end
