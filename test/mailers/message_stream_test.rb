# frozen_string_literal: true

require 'test_helper'

class MessageStreamTest < ActionMailer::TestCase
  # Set up the mock template for account_created
  setup do
    # Create mock template for application_notifications_account_created
    @account_created_template = mock('EmailTemplate')
    @account_created_template.stubs(:render).returns(['Welcome to the System', 'Account creation email body'])
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_account_created', format: :text, locale: 'en').returns(@account_created_template)
    @account_created_template.stubs(:enabled?).returns(true)

    # Create mock template for user_mailer_password_reset
    @password_reset_template = mock('EmailTemplate')
    @password_reset_template.stubs(:enabled?).returns(true)
    @password_reset_template.stubs(:render).returns(['Reset Your Password', 'Password reset email body'])
    EmailTemplate.stubs(:find_by!).with(name: 'user_mailer_password_reset', format: :text, locale: 'en').returns(@password_reset_template)
  end

  test 'notifications mailer uses correct message stream' do
    # Create a constituent user and application using FactoryBot
    application = create(:application, :completed)
    constituent = application.user
    temp_password = 'tempPassword123'

    email = ApplicationNotificationsMailer.account_created(constituent, temp_password)

    assert_equal 'notifications', email.message_stream
  end

  test 'transactional mailer uses correct message stream' do
    # Create an admin user using FactoryBot
    admin = create(:admin)

    # Use capture_emails to get the email
    email = nil
    assert_emails 1 do
      email = UserMailer.with(user: admin).password_reset
      email.deliver_now
    end

    assert_equal 'user-email', email.message_stream
  end
end
