# frozen_string_literal: true

require 'test_helper'

class NotificationServiceTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @constituent = create(:constituent)
    @application = create(:application, user: @constituent)
  end

  test 'create_and_deliver! creates a notification and enqueues an email job' do
    assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
      notification = nil
      assert_difference 'Notification.count', 1 do
        notification = NotificationService.create_and_deliver!(
          type: :proof_approved,
          recipient: @constituent,
          actor: @admin,
          notifiable: @application,
          channel: :email
        )
      end

      assert_not_nil notification
      assert_equal 'proof_approved', notification.action
      assert_equal @constituent, notification.recipient
      assert_equal @application, notification.notifiable
      assert_equal 'email', notification.metadata['channel']
      assert_equal 'email', notification.metadata['actual_delivery_channel']
      assert_equal 'requested_channel', notification.metadata['delivery_route_reason']
    end
  end

  test 'create_and_deliver! tracks actual letter routing when mailer returns noop delivery' do
    @constituent.update!(communication_preference: 'letter')
    ApplicationNotificationsMailer.stubs(:proof_approved).returns(
      ApplicationMailer::NoopDelivery.new
    )

    notification = NotificationService.create_and_deliver!(
      type: :proof_approved,
      recipient: @constituent,
      actor: @admin,
      notifiable: @application,
      channel: :email
    )

    assert_not_nil notification
    notification.reload
    assert_equal 'email', notification.metadata['channel']
    assert_equal 'letter', notification.metadata['actual_delivery_channel']
    assert_equal 'preference', notification.metadata['delivery_route_reason']
  end

  test 'create_and_deliver! infers actual letter routing for preference-routed actions' do
    @constituent.update!(communication_preference: 'letter')
    mail_delivery = mock('mail_delivery')
    mail_delivery.stubs(:deliver_later).returns(true)
    ApplicationNotificationsMailer.stubs(:proof_approved).returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :proof_approved,
      recipient: @constituent,
      actor: @admin,
      notifiable: @application,
      channel: :email
    )

    assert_not_nil notification
    notification.reload
    assert_equal 'email', notification.metadata['channel']
    assert_equal 'letter', notification.metadata['actual_delivery_channel']
    assert_equal 'preference', notification.metadata['delivery_route_reason']
  end

  test 'create_and_deliver! records actual email when requested channel is letter for non-letter mailer actions' do
    mail_delivery = mock('mail_delivery')
    mail_delivery.stubs(:deliver_later).returns(true)
    VendorNotificationsMailer.stubs(:w9_approved).returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :w9_approved,
      recipient: @constituent,
      actor: @admin,
      notifiable: @application,
      channel: :letter
    )

    assert_not_nil notification
    notification.reload
    assert_equal 'letter', notification.metadata['channel']
    assert_equal 'email', notification.metadata['actual_delivery_channel']
    assert_equal 'mailer_override', notification.metadata['delivery_route_reason']
  end

  test 'create_and_deliver! does NOT create an Event record directly' do
    # AuditEventService.log is now called by the methods that use NotificationService,
    # not by NotificationService itself. So, this test should assert no direct Event creation.
    assert_no_difference 'Event.count' do
      NotificationService.create_and_deliver!(
        type: :proof_approved,
        recipient: @constituent,
        actor: @admin,
        notifiable: @application
      )
    end
  end

  test 'create_and_deliver! with deliver: false does not enqueue a job' do
    assert_no_enqueued_jobs do
      NotificationService.create_and_deliver!(
        type: :proof_approved,
        recipient: @constituent,
        actor: @admin,
        notifiable: @application,
        deliver: false
      )
    end
  end

  test 'handle_delivery_error updates notification status on mailer failure' do
    # Stub the mailer to raise an error
    ApplicationNotificationsMailer.stubs(:proof_approved).raises(Net::SMTPAuthenticationError, 'SMTP auth error')

    assert_no_difference 'Notification.count' do # Should not create a new notification on failure, but update existing one
      # We expect it to fail, so we check the created notification afterwards
    end

    # Manually create the notification to simulate the state right before delivery
    notification = Notification.create!(
      recipient: @constituent,
      actor: @admin,
      action: 'proof_approved',
      notifiable: @application
    )

    # Call the delivery part which should fail and handle the error
    NotificationService.send(:deliver_notification!, notification, channel: :email)

    notification.reload
    assert_equal 'error', notification.delivery_status
    assert_equal 'SMTP auth error', notification.metadata.dig('delivery_error', 'message')
  end

  test 'create_and_deliver! returns nil and logs error when creation fails' do
    # Force a validation error
    Notification.any_instance.stubs(:valid?).returns(false)

    Rails.logger.expects(:error).at_least_once

    notification = NotificationService.create_and_deliver!(
      type: :proof_approved,
      recipient: @constituent,
      actor: @admin,
      notifiable: @application
    )

    assert_nil notification
  end

  test 'resolve_mailer correctly maps actions to mailers' do
    # Test a few examples
    proof_approved_notif = Notification.new(action: 'proof_approved')
    mailer, method = NotificationService.send(:resolve_mailer, proof_approved_notif)
    assert_equal ApplicationNotificationsMailer, mailer
    assert_equal :proof_approved, method

    medical_cert_notif = Notification.new(action: 'medical_certification_rejected')
    mailer, method = NotificationService.send(:resolve_mailer, medical_cert_notif)
    assert_nil mailer
    assert_nil method

    requested_cert_notif = Notification.new(action: 'medical_certification_requested')
    mailer, method = NotificationService.send(:resolve_mailer, requested_cert_notif)
    assert_equal MedicalProviderMailer, mailer
    assert_equal :requested, method

    training_requested_notif = Notification.new(action: 'training_requested')
    mailer, method = NotificationService.send(:resolve_mailer, training_requested_notif)
    assert_equal ApplicationNotificationsMailer, mailer
    assert_equal :training_requested, method

    unknown_notif = Notification.new(action: 'some_unknown_action')
    mailer, method = NotificationService.send(:resolve_mailer, unknown_notif)
    assert_nil mailer
    assert_nil method
  end

  test 'training_requested routes application and notification context to application mailer' do
    mail_delivery = mock('mail_delivery')
    mail_delivery.expects(:deliver_later).returns(true)
    ApplicationNotificationsMailer.expects(:training_requested)
                                  .with(@application, instance_of(Notification))
                                  .returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :training_requested,
      recipient: @admin,
      actor: @constituent,
      notifiable: @application,
      channel: :email
    )

    assert_not_nil notification
    assert_equal 'email', notification.reload.metadata['actual_delivery_channel']
  end
end
