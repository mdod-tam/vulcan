# frozen_string_literal: true

require 'test_helper'

class ApplicationMailerTest < ActionMailer::TestCase
  test 'a required email without a recipient raises a recorded delivery skip before rendering' do
    ensure_system_audit_actor!
    mailer = ApplicationMailer.new
    template = mock
    template.expects(:render).never

    error = assert_raises(ApplicationMailer::DeliverySkipped) do
      mailer.send(:send_email, nil, template, {}, required_delivery: true)
    end

    assert_equal 'missing_recipient', error.reason
    assert_equal 'missing_recipient', EmailDelivery::Current.denial_reason
    assert_empty ActionMailer::Base.deliveries
  ensure
    EmailDelivery::Current.reset
  end

  test 'normalize_locale normalizes explicit locale value' do
    mailer = ApplicationMailer.new

    resolved = mailer.send(:normalize_locale, 'es-MX')

    assert_equal 'es', resolved
  end

  test 'text template lookup normalizes the recipient locale and falls back to the default template' do
    name = "mailer_locale_lookup_#{SecureRandom.hex(4)}"
    english = create(:email_template, :text, name: name, locale: 'en')
    spanish = create(:email_template, :text, name: name, locale: 'es')
    mailer = ApplicationMailer.new

    assert_equal spanish, mailer.send(:find_text_template, name, locale: 'es-MX')

    spanish.destroy!

    assert_equal english, mailer.send(:find_text_template, name, locale: 'es-MX')
  end

  test 'text template lookup raises when the requested and default templates are missing' do
    mailer = ApplicationMailer.new
    name = "missing_mailer_template_#{SecureRandom.hex(4)}"

    assert_raises(ActiveRecord::RecordNotFound) { mailer.send(:find_text_template, name, locale: 'es') }
    assert_raises(ActiveRecord::RecordNotFound) { mailer.send(:find_text_template, name, locale: 'en') }
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

  test 'header title renders Liquid subject without requiring body variables' do
    template = create(
      :email_template,
      :text,
      subject: 'Hello {{ user.first_name }}',
      body: 'Body {{ body_only }}',
      variables: { 'required' => ['user.first_name', 'body_only'], 'optional' => [] },
      syntax: :liquid
    )
    mailer = ApplicationMailer.new

    title = mailer.send(
      :header_title_from_template_subject,
      template: template,
      subject_variables: { user: { first_name: 'Alex' } },
      fallback: 'Fallback title'
    )

    assert_equal 'Hello Alex', title
  end
end
