# frozen_string_literal: true

require 'test_helper'

module Webhooks
  class TwilioControllerTest < ActionDispatch::IntegrationTest
    test 'retired fax callbacks return not found without changing delivery state' do
      original_notifications = Notification.order(:id).map(&:attributes)

      assert_no_difference ['EmailDeliveryAttempt.count', 'Event.count'] do
        assert_no_enqueued_jobs do
          post '/webhooks/twilio/fax_status', params: { FaxSid: 'FX_RETIRED', Status: 'failed' }
        end
      end

      assert_response :not_found
      assert_equal original_notifications, Notification.order(:id).map(&:attributes)
    end
  end
end
