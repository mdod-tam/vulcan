# frozen_string_literal: true

require 'test_helper'

class UserMailerTest < ActionMailer::TestCase
  def mock_template(subject_format, body_format)
    template_instance = mock("email_template_instance_#{subject_format.gsub(/\s+/, '_')}")

    template_instance.stubs(:render).with(any_parameters).returns([subject_format, body_format])

    template_instance.stubs(:subject).returns(subject_format)
    template_instance.stubs(:body).returns(body_format)
    template_instance.stubs(:enabled?).returns(true)

    template_instance
  end

  setup do
    # Stored templates are text-only, so only the text format is stubbed. The mocks hold the
    # output after variable substitution.
    password_reset_template = mock_template(
      'Password reset',
      "Password reset link:\nhttp://example.com/password/edit?token=test-password-reset-token"
    )

    spanish_password_reset_template = mock_template(
      'Restablecer contrasena',
      "Enlace de restablecimiento de contrasena:\nhttp://example.com/password/edit?token=test-password-reset-token"
    )

    EmailTemplate.stubs(:find_by!).with(name: 'user_mailer_password_reset', format: :text, locale: 'en')
                 .returns(password_reset_template)

    EmailTemplate.stubs(:find_by!).with(name: 'user_mailer_password_reset', format: :text, locale: 'es')
                 .returns(spanish_password_reset_template)

    UserMailer.any_instance.stubs(:edit_password_url).returns('http://example.com/password/edit?token=test-password-reset-token')
  end

  test 'password_reset' do
    user = create(:user)
    user.stubs(:generate_token_for).with(:password_reset).returns('test-password-reset-token')

    emails = capture_emails do
      UserMailer.with(user: user).password_reset.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [user.email], email.to
    assert_equal 'Password reset', email.subject

    reset_url = 'http://example.com/password/edit?token=test-password-reset-token'
    expected_body = "Password reset link:\n#{reset_url}"
    assert_includes decoded_text_part(email), expected_body
  end

  test 'password_reset link carries the locale the email is written in' do
    user = create(:constituent, locale: 'es')
    user.stubs(:generate_token_for).with(:password_reset).returns('test-password-reset-token')
    UserMailer.any_instance.expects(:edit_password_url)
              .with(has_entries(token: 'test-password-reset-token', locale: 'es'))
              .returns('http://example.com/password/edit?locale=es&token=test-password-reset-token')

    emails = capture_emails { UserMailer.with(user: user).password_reset.deliver_now }

    assert_equal 1, emails.size
  end

  test 'password_reset uses Spanish template for Spanish locale constituent' do
    user = create(:constituent, locale: 'es')
    user.stubs(:generate_token_for).with(:password_reset).returns('test-password-reset-token')

    emails = capture_emails do
      UserMailer.with(user: user).password_reset.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first
    assert_equal [user.email], email.to
    assert_equal 'Restablecer contrasena', email.subject
  end

  test 'password_reset uses Spanish template for Spanish locale staff user when available' do
    user = create(:admin, locale: 'es')
    user.stubs(:generate_token_for).with(:password_reset).returns('test-password-reset-token')

    emails = capture_emails do
      UserMailer.with(user: user).password_reset.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first
    assert_equal [user.email], email.to
    assert_equal 'Restablecer contrasena', email.subject
  end

  test 'password_reset renders a real Liquid text template' do
    EmailTemplate.unstub(:find_by!)
    user = create(:user)
    user.stubs(:generate_token_for).with(:password_reset).returns('test-password-reset-token')

    create_real_text_email_template(
      name: 'user_mailer_password_reset',
      subject: 'Reset password for {{ user_email }}',
      body: 'Reset link: {{ reset_url }} for {{ user_email }}',
      required: %w[user_email reset_url]
    )

    email = UserMailer.with(user: user).password_reset.deliver_now

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [user.email], email.to
    assert_equal "Reset password for #{user.email}", email.subject
    assert_includes email.body.to_s, 'http://example.com/password/edit?token=test-password-reset-token'
    assert_includes email.body.to_s, user.email
  end

  test 'password_reset mailer error audit metadata omits exception text' do
    user = create(:user)
    raw_url = 'http://example.com/password/edit?token=secret-token'

    UserMailer.any_instance.stubs(:send_email).raises(StandardError.new("boom #{raw_url} #{user.email}"))

    assert_difference -> { Event.where(action: 'email_delivery_error', auditable: user).count }, 1 do
      assert_raises(StandardError) do
        UserMailer.with(user: user).password_reset.deliver_now
      end
    end

    event = Event.where(action: 'email_delivery_error', auditable: user).last

    assert_equal 'StandardError', event.metadata.fetch('error_class')
    assert_not event.metadata.key?('error_message')
    assert_not event.metadata.key?('backtrace')
    assert_not_includes event.metadata.to_json, raw_url
    assert_not_includes event.metadata.to_json, user.email
    assert_not event.metadata.key?('variables')
  end
end
