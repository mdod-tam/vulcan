# frozen_string_literal: true

require 'test_helper'

# The footer's organization name is recipient-visible, so each mailer's default is pinned here.
class EnvelopeVariablesTest < ActiveSupport::TestCase
  def footer_for(mailer_class, **)
    mailer_class.new.send(:build_base_email_variables, template: nil, locale: 'en', **)[:footer_text]
  end

  test 'application notifications default to the program name without "Program" when no name is given' do
    footer = footer_for(ApplicationNotificationsMailer)

    assert_includes footer, 'Maryland Accessible Telecommunications'
    assert_not_includes footer, 'Telecommunications Program'
  end

  test 'an organization name passed by the caller wins' do
    assert_includes footer_for(ApplicationNotificationsMailer, organization_name: 'MAT Program'), 'MAT Program'
  end
end
