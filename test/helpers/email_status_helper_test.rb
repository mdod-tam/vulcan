# frozen_string_literal: true

require 'test_helper'

class EmailStatusHelperTest < ActionView::TestCase
  test 'a notification without delivery evidence has no panel' do
    notification = create(:notification, delivery_status: nil)
    assert_empty delivery_visibility(notification)
  end

  test 'a queued notification retains its recorded status without a provider attempt' do
    notification = create(:notification, delivery_status: :queued)
    assert_includes delivery_visibility(notification), 'data-delivery-status="queued"'
  end

  test 'an attempted but unconfirmed send remains visible as unknown' do
    notification = create(:notification)
    notification.email_delivery_attempts.create!(correlation_id: SecureRandom.uuid, recipient_key: EmailDeliveryAttempt.recipient_key('a@example.test'),
                                                 destination: 'a@example.test', server_id: '23', mail_action: 'UserMailer#password_reset', attempted_at: Time.current)
    assert_includes delivery_visibility(notification), 'data-delivery-status="unknown"'
  end
end
