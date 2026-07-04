# frozen_string_literal: true

require 'test_helper'

class UserMailerTest < ActionMailer::TestCase
  # Helper to create mock templates that respond to render method
  def mock_template(subject_format, body_format)
    template_instance = mock("email_template_instance_#{subject_format.gsub(/\s+/, '_')}") # Unique name for easier debugging

    # Stub the render method to return [rendered_subject, rendered_body]
    # This simulates what the real EmailTemplate.render method does
    template_instance.stubs(:render).with(any_parameters).returns([subject_format, body_format])

    # Still stub subject and body for inspection if needed
    template_instance.stubs(:subject).returns(subject_format)
    template_instance.stubs(:body).returns(body_format)
    template_instance.stubs(:enabled?).returns(true)

    template_instance
  end

  setup do
    # Stored templates remain text-only until explicit HTML template support is added.

    # Stub EmailTemplate.find_by! to return mocks that respond to subject and body
    # Create template mocks with the expected rendered output (after substitution)
    password_reset_template = mock_template(
      'Password reset',
      "Password reset link:\nhttp://example.com/password/edit?token=test-password-reset-token"
    )

    spanish_password_reset_template = mock_template(
      'Restablecer contrasena',
      "Enlace de restablecimiento de contrasena:\nhttp://example.com/password/edit?token=test-password-reset-token"
    )

    # Stub the find_by! calls to return our mocks
    EmailTemplate.stubs(:find_by!).with(name: 'user_mailer_password_reset', format: :text, locale: 'en')
                 .returns(password_reset_template)

    EmailTemplate.stubs(:find_by!).with(name: 'user_mailer_password_reset', format: :text, locale: 'es')
                 .returns(spanish_password_reset_template)

    # Stub the URL helpers that our mailer uses
    UserMailer.any_instance.stubs(:edit_password_url).returns('http://example.com/password/edit?token=test-password-reset-token')
  end

  test 'password_reset' do
    # Create unique user for this test
    user = create(:user)
    # Stub token generation to return predictable values for testing
    user.stubs(:generate_token_for).with(:password_reset).returns('test-password-reset-token')

    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      UserMailer.with(user: user).password_reset.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [user.email], email.to
    assert_equal 'Password reset', email.subject # Assert subject matches the mock template subject

    # Manually interpolate the expected body format string to compare with the main body
    reset_url = 'http://example.com/password/edit?token=test-password-reset-token'
    expected_body = "Password reset link:\n#{reset_url}"
    assert_includes decoded_text_part(email), expected_body
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

  test 'password_reset mailer error audit metadata redacts reset URLs' do
    user = create(:user)
    raw_url = 'http://example.com/password/edit?token=secret-token'

    UserMailer.any_instance.stubs(:send_email).raises(StandardError.new("boom #{raw_url} #{user.email}"))

    assert_difference -> { Event.where(action: 'email_delivery_error', auditable: user).count }, 1 do
      assert_raises(StandardError) do
        UserMailer.with(user: user).password_reset.deliver_now
      end
    end

    event = Event.where(action: 'email_delivery_error', auditable: user).last
    variables = event.metadata.fetch('variables')
    variables_json = event.metadata.fetch('variables').to_json

    assert_includes event.metadata.fetch('error_message'), '[REDACTED_URL]'
    assert_includes event.metadata.fetch('error_message'), '[REDACTED_EMAIL]'
    assert_not_includes event.metadata.fetch('error_message'), raw_url
    assert_not_includes event.metadata.fetch('error_message'), user.email
    assert_equal '[REDACTED]', variables.fetch('user_email')
    assert_not_includes variables_json, user.email
    assert_not_includes variables_json, raw_url
    assert_not_includes variables_json, 'secret-token'
    assert_includes variables_json, '[REDACTED]'
  end
end
