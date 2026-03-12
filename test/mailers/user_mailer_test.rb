# frozen_string_literal: true

require 'test_helper'
require 'ostruct' # Ensure OpenStruct is required

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
    # Per user feedback, HTML emails are not used. Only stub for :text format.
    # If the mailer attempts to find_by!(format: :html), it should fail (e.g., RecordNotFound)
    # as no HTML templates should be seeded for these, and we provide no stub.

    # Stub EmailTemplate.find_by! to return mocks that respond to subject and body
    # Create template mocks with the expected rendered output (after substitution)
    password_reset_template = mock_template(
      'Password reset',
      'Text Body with http://example.com/password/edit?token=test-password-reset-token'
    )

    email_verification_template = mock_template(
      'Email verification',
      'Text Body with http://example.com/constituent_portal/applications/verify?token=test-email-verification-token'
    )

    # Stub the find_by! calls to return our mocks
    EmailTemplate.stubs(:find_by!).with(name: 'user_mailer_password_reset', format: :text, locale: 'en')
                 .returns(password_reset_template)

    EmailTemplate.stubs(:find_by!).with(name: 'user_mailer_email_verification', format: :text, locale: 'en')
                 .returns(email_verification_template)

    # Stub the URL helpers that our mailer uses
    UserMailer.any_instance.stubs(:edit_password_url).returns('http://example.com/password/edit?token=test-password-reset-token')
    UserMailer.any_instance.stubs(:verify_constituent_portal_application_url).returns('http://example.com/constituent_portal/applications/verify?token=test-email-verification-token')
  end

  test 'password_reset' do
    # Create unique user for this test
    user = create(:user)
    # Stub token generation to return predictable values for testing
    user.stubs(:generate_token_for).with(:password_reset).returns('test-password-reset-token')
    user.stubs(:generate_token_for).with(:email_verification).returns('test-email-verification-token')

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

    # For non-multipart emails, we check the body directly
    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    # Manually interpolate the expected body format string to compare with the main body
    expected_body = 'Text Body with http://example.com/password/edit?token=test-password-reset-token'
    assert_includes email.body.to_s, expected_body
  end

  test 'email_verification' do
    # Create unique user for this test
    user = create(:user)
    # Stub token generation to return predictable values for testing
    user.stubs(:generate_token_for).with(:password_reset).returns('test-password-reset-token')
    user.stubs(:generate_token_for).with(:email_verification).returns('test-email-verification-token')

    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      UserMailer.with(user: user).email_verification.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [user.email], email.to
    assert_equal 'Email verification', email.subject # Assert subject matches the mock template subject

    # For non-multipart emails, we check the body directly
    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    # Manually interpolate the expected body format string to compare with the main body
    expected_body = 'Text Body with http://example.com/constituent_portal/applications/verify?token=test-email-verification-token'
    assert_includes email.body.to_s, expected_body
  end
end
