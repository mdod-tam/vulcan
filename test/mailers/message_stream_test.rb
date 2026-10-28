# frozen_string_literal: true

require 'test_helper'

class MessageStreamTest < ActionMailer::TestCase
  setup do
    @account_created_template = mock('EmailTemplate')
    @account_created_template.stubs(:subject).returns('Welcome to the System')
    @account_created_template.stubs(:render_subject).returns('Welcome to the System')
    @account_created_template.stubs(:render).returns(['Welcome to the System', 'Account creation email body'])
    ApplicationNotificationsMailer.any_instance.stubs(:find_text_template)
                                  .with('application_notifications_account_created', locale: 'en')
                                  .returns(@account_created_template)
    @account_created_template.stubs(:enabled?).returns(true)

    @password_reset_template = mock('EmailTemplate')
    @password_reset_template.stubs(:enabled?).returns(true)
    @password_reset_template.stubs(:subject).returns('Reset Your Password')
    @password_reset_template.stubs(:render_subject).returns('Reset Your Password')
    @password_reset_template.stubs(:render).returns(['Reset Your Password', 'Password reset email body'])
    UserMailer.any_instance.stubs(:find_text_template)
              .with('user_mailer_password_reset', locale: 'en')
              .returns(@password_reset_template)
  end

  test 'notifications mailer uses correct message stream' do
    application = create(:application, :completed)
    constituent = application.user

    email = ApplicationNotificationsMailer.account_created(constituent)

    assert_equal 'notifications', email.message_stream
  end

  test 'transactional mailer uses correct message stream' do
    admin = create(:admin)

    email = nil
    assert_emails 1 do
      email = UserMailer.with(user: admin).password_reset
      email.deliver_now
    end

    assert_equal 'outbound', email.message_stream
  end
end
