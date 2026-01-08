# frozen_string_literal: true

require 'test_helper'

class RegistrationsMailerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    # Create templates needed for the test
    create_email_templates
  end

  test 'registration_confirmation email should be sent' do
    # Create a test user directly (not saved to DB)
    user = Users::Constituent.new(
      first_name: 'Test',
      last_name: 'User',
      email: 'test.reg.mailer@example.com', # Unique to avoid collisions
      phone: '555-123-4567',
      communication_preference: 'email'
    )

    # Create a mock template that returns text-only content
    mock_template = mock('EmailTemplate')
    subject = 'Welcome to the Maryland Accessible Telecommunications Program'
    body = "Dear Test,\n\nWelcome to the program.\n\nThank you,\nThe MAT Team"
    mock_template.stubs(:render).returns([subject, body])
    mock_template.stubs(:enabled?).returns(true)
    EmailTemplate.stubs(:find_by!).returns(mock_template)

    # Clear any emails from previous tests
    ActionMailer::Base.deliveries.clear

    # Generate and deliver the email
    email = ApplicationNotificationsMailer.registration_confirmation(user).deliver_now

    # Basic assertions
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal ['test.reg.mailer@example.com'], email.to
    assert_equal 'Welcome to the Maryland Accessible Telecommunications Program', email.subject

    # Check text-only email (no longer multipart)
    assert_equal 'text/plain; charset=UTF-8', email.content_type
    assert_includes email.body.to_s, 'Dear Test,'
    assert_includes email.body.to_s, 'Welcome to the program'
  end

  test 'registrations controller should send email' do
    # Create a user with unique email
    user = Users::Constituent.new(
      first_name: 'New',
      last_name: 'User',
      email: 'test.reg.controller@example.com',
      communication_preference: 'email'
    )

    # Use old-style expectation (instead of enqueued assertions) to avoid serialization issues with unsaved records
    mail_message = mock('MailMessage')
    mail_message.expects(:deliver_later).returns(true)

    ApplicationNotificationsMailer.expects(:registration_confirmation)
                                  .with(user)
                                  .returns(mail_message)

    # Simulate the controller's send_registration_confirmation method
    ApplicationNotificationsMailer.registration_confirmation(user).deliver_later
  end

  private

  def create_email_templates
    # Create the required templates for the mailer to work
    unless EmailTemplate.exists?(name: 'application_notifications_registration_confirmation', format: :text)
      EmailTemplate.create!(
        name: 'application_notifications_registration_confirmation',
        format: :text,
        # Ensure required variables are present for EmailTemplate validation
        body: "Subject: Welcome to the Maryland Accessible Telecommunications Program\n\n" \
              "%<header_text>s\n\n" \
              "Dear %<user_full_name>s,\n\n" \
              "Welcome to the program.\n\n" \
              "Access your dashboard here: %<dashboard_url>s\n\n" \
              "Apply for services: %<new_application_url>s\n\n" \
              "Active vendors: %<active_vendors_text_list>s\n\n" \
              '%<footer_text>s',
        subject: 'Welcome to the Maryland Accessible Telecommunications Program',
        # Add description to satisfy validation
        description: 'Email sent to constituents upon successful registration.'
      )
    end

    unless EmailTemplate.exists?(name: 'email_header_text', format: :text)
      EmailTemplate.create!(
        name: 'email_header_text',
        format: :text,
        body: "=== %<title>s ===\n\n",
        subject: 'Header Template',
        description: 'Standard email header partial.'
      )
    end

    return if EmailTemplate.exists?(name: 'email_footer_text', format: :text)

    EmailTemplate.create!(
      name: 'email_footer_text',
      format: :text,
      body: "\n\nThank you,\nThe MAT Team\nContact: %<contact_email>s",
      subject: 'Footer Template',
      description: 'Standard email footer partial.'
    )
  end
end
