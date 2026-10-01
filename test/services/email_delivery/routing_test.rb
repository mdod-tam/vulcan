# frozen_string_literal: true

require 'test_helper'

module EmailDelivery
  class RoutingTest < ActiveSupport::TestCase
    test 'effective preference takes precedence with explicit overrides preserved' do
      recipient = Struct.new(:effective_communication_preference, :communication_preference).new('letter', 'email')
      assert Routing.prefers_letter?(recipient)
      assert_not Routing.prefers_letter?(recipient, override: 'email')
      assert Routing.prefers_letter?(recipient, override: 'letter')
      assert Routing.prefers_letter?(Struct.new(:communication_preference).new(:letter))
      assert_not Routing.prefers_letter?(nil)
    end

    test 'mailer and notification routing use the same guardian preference' do
      guardian = create(:constituent, communication_preference: :letter)
      dependent = create(:constituent, communication_preference: :email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
      notification = Notification.new(recipient: dependent, action: 'training_scheduled')

      assert ApplicationMailer.new.send(:prefers_letter_delivery?, dependent)
      assert NotificationService.new.send(:letter_preference_route?, notification)
    end
  end
end
