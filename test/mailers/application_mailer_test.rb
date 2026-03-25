# frozen_string_literal: true

require 'test_helper'

class ApplicationMailerTest < ActionMailer::TestCase
  test 'normalize_locale normalizes explicit locale value' do
    mailer = ApplicationMailer.new

    resolved = mailer.send(:normalize_locale, 'es-MX')

    assert_equal 'es', resolved
  end

  test 'resolve_template_locale falls back to recipient locale' do
    recipient = Struct.new(:locale).new('es-MX')
    mailer = ApplicationMailer.new

    resolved = mailer.send(:resolve_template_locale, recipient: recipient)

    assert_equal 'es', resolved
  end

  test 'resolve_template_locale prefers recipient effective_locale when present' do
    recipient = Struct.new(:locale) do
      def effective_locale
        'es-MX'
      end
    end.new('en')
    mailer = ApplicationMailer.new

    resolved = mailer.send(:resolve_template_locale, recipient: recipient)

    assert_equal 'es', resolved
  end

  test 'resolve_template_locale falls back to default locale instead of ambient i18n locale' do
    mailer = ApplicationMailer.new

    I18n.with_locale(:es) do
      resolved = mailer.send(:resolve_template_locale)
      assert_equal I18n.default_locale.to_s, resolved
    end
  end
end
