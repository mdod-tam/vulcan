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

    test 'failure message follows the active locale, including how it joins the validation messages' do
      user = User.new
      user.errors.add(:base, 'primero')
      user.errors.add(:base, 'segundo')

      I18n.with_locale(:es) do
        assert_equal 'No se pudo actualizar la contraseña. primero y segundo.', PasswordUpdateService.failure_message(user)
        assert_equal 'a, b y c', %w[a b c].to_sentence
      end
      assert_equal 'Unable to update password. primero and segundo.', PasswordUpdateService.failure_message(user)
    end
  end
end
