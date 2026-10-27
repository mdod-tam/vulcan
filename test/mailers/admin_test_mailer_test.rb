# frozen_string_literal: true

require 'test_helper'

class AdminTestMailerTest < ActionMailer::TestCase
  setup do
    @admin = create(:admin)
    @template_name = 'application_notifications_account_created'
    @subject = 'Test Email Subject'
    @body = 'This is a test email body for template testing.'
  end

  test 'test_email with text format' do
    params = {
      user: @admin,
      recipient_email: @admin.email,
      template_name: @template_name,
      subject: @subject,
      body: @body,
      format: 'text'
    }

    email = nil
    assert_emails 1 do
      email = AdminTestMailer.with(params).test_email
      email.deliver_now
    end

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@admin.email], email.to
    assert_equal "[TEST] #{@subject} (Template: #{@template_name})", email.subject

    assert_equal @body.to_s, email.body.to_s.strip
  end

  test 'test_email respects custom recipient_email' do
    custom_email = 'test.recipient@example.com'

    params = {
      user: @admin,
      recipient_email: custom_email,
      template_name: @template_name,
      subject: @subject,
      body: @body,
      format: 'text'
    }

    email = nil
    assert_emails 1 do
      email = AdminTestMailer.with(params).test_email
      email.deliver_now
    end

    assert_equal [custom_email], email.to
  end

  test 'test_email falls back to user email if recipient_email is nil' do
    params = {
      user: @admin,
      recipient_email: nil,
      template_name: @template_name,
      subject: @subject,
      body: @body,
      format: 'text'
    }

    email = nil
    assert_emails 1 do
      email = AdminTestMailer.with(params).test_email
      email.deliver_now
    end

    assert_equal [@admin.email], email.to
  end

  test 'test_email converts format to symbol' do
    params = {
      user: @admin,
      template_name: @template_name,
      subject: @subject,
      body: @body,
      format: 'text'
    }

    email = AdminTestMailer.with(params).test_email

    # The conversion is not observable directly. The content type may carry a charset suffix.
    assert_includes email.content_type, 'text/plain'
  end
end
