# frozen_string_literal: true

require 'test_helper'

module Users
  class PasswordUpdateServiceTest < ActiveSupport::TestCase
    test 'inspect omits the password challenge, new password, and confirmation' do
      service = PasswordUpdateService.new(User.new, 'challenge-marker', 'new-password-marker', 'confirmation-marker')

      %w[challenge-marker new-password-marker confirmation-marker].each do |marker|
        assert_not_includes service.inspect, marker
      end
    end
  end
end
