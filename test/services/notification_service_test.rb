# frozen_string_literal: true

require 'test_helper'

class NotificationServiceTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @constituent = create(:constituent)
    @application = create(:application, user: @constituent)
  end

  teardown do
    Current.reset
  end

  test 'create_and_deliver! creates a notification and enqueues an email job for deliverable actions' do
    assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
      notification = nil
      assert_difference 'Notification.count', 1 do
        notification = NotificationService.create_and_deliver!(
          type: :proof_rejected,
          recipient: @constituent,
          actor: @admin,
          notifiable: @application,
          metadata: { proof_type: 'income', rejection_reason: 'Missing documentation' },
          channel: :email
        )
      end

      assert_not_nil notification
      assert_equal 'proof_rejected', notification.action
      assert_equal @constituent, notification.recipient
      assert_equal @application, notification.notifiable
      assert_equal 'email', notification.metadata['channel']
      assert_equal 'email', notification.metadata['actual_delivery_channel']
      assert_equal 'requested_channel', notification.metadata['delivery_route_reason']
    end
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

  test 'proof approval notifications are record-only delivery noops' do
    assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
      notification = NotificationService.create_and_deliver!(
        type: :proof_approved,
        recipient: @constituent,
        actor: @admin,
        notifiable: @application,
        channel: :email
      )

      assert_not_nil notification
      notification.reload
      assert_equal 'proof_approved', notification.action
      assert_equal 'none', notification.metadata['actual_delivery_channel']
      assert_equal 'no_email_action', notification.metadata['delivery_route_reason']
      assert_nil notification.delivery_status
    end
  end

  test 'medical certification approval notifications are record-only delivery noops' do
    assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
      notification = NotificationService.create_and_deliver!(
        type: :medical_certification_approved,
        recipient: @constituent,
        actor: @admin,
        notifiable: @application,
        channel: :email
      )

      assert_not_nil notification
      notification.reload
      assert_equal 'medical_certification_approved', notification.action
      assert_equal 'none', notification.metadata['actual_delivery_channel']
      assert_equal 'no_email_action', notification.metadata['delivery_route_reason']
      assert_nil notification.delivery_status
    end
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
    ApplicationNotificationsMailer.stubs(:proof_rejected).raises(Net::SMTPAuthenticationError, 'SMTP auth error')

    assert_no_difference 'Notification.count' do # Should not create a new notification on failure, but update existing one
      # We expect it to fail, so we check the created notification afterwards
    end

    # Manually create the notification to simulate the state right before delivery
    notification = Notification.create!(
      recipient: @constituent,
      actor: @admin,
      action: 'proof_rejected',
      notifiable: @application,
      metadata: { proof_type: 'income' }
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
    assert_nil mailer
    assert_nil method

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

  test 'proof attached routes proof type from metadata to proof received mailer' do
    mail_delivery = mock('mail_delivery')
    mail_delivery.expects(:deliver_later).returns(true)
    ApplicationNotificationsMailer.expects(:proof_received)
                                  .with(@application, 'income')
                                  .returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :income_proof_attached,
      recipient: @constituent,
      actor: @constituent,
      notifiable: @application,
      metadata: { proof_type: 'income' },
      channel: :email
    )

    assert_not_nil notification
    assert_equal 'email', notification.reload.metadata['actual_delivery_channel']
  end

  test 'proof attached falls back to action name for proof received mailer' do
    mail_delivery = mock('mail_delivery')
    mail_delivery.expects(:deliver_later).returns(true)
    ApplicationNotificationsMailer.expects(:proof_received)
                                  .with(@application, 'id')
                                  .returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :id_proof_attached,
      recipient: @constituent,
      actor: @constituent,
      notifiable: @application,
      channel: :email
    )

    assert_not_nil notification
    assert_equal 'email', notification.reload.metadata['actual_delivery_channel']
  end

  test 'proof rejected with proof review notifiable routes application and review to mailer' do
    Current.paper_context = true
    proof_review = create(:proof_review, :rejected, application: @application, admin: @admin, proof_type: :income)
    Current.paper_context = false

    mail_delivery = mock('mail_delivery')
    mail_delivery.expects(:deliver_later).returns(true)
    ApplicationNotificationsMailer.expects(:proof_rejected)
                                  .with(@application, proof_review, recipient: @constituent)
                                  .returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :proof_rejected,
      recipient: @constituent,
      actor: @admin,
      notifiable: proof_review,
      metadata: { proof_type: 'income' },
      channel: :email
    )

    assert_not_nil notification
    assert_equal 'email', notification.reload.metadata['actual_delivery_channel']
  end

  test 'typed proof rejected routes proof review lookup to proof rejected mailer' do
    Current.paper_context = true
    proof_review = create(:proof_review, :rejected, application: @application, admin: @admin, proof_type: :income)
    Current.paper_context = false

    mail_delivery = mock('mail_delivery')
    mail_delivery.expects(:deliver_later).returns(true)
    ApplicationNotificationsMailer.expects(:proof_rejected)
                                  .with(@application, proof_review, recipient: @constituent)
                                  .returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :income_proof_rejected,
      recipient: @constituent,
      actor: @admin,
      notifiable: @application,
      channel: :email
    )

    assert_not_nil notification
    assert_equal 'email', notification.reload.metadata['actual_delivery_channel']
  end

  test 'id proof attached is preference routed' do
    @constituent.update!(communication_preference: 'letter')
    mail_delivery = mock('mail_delivery')
    mail_delivery.expects(:deliver_later).returns(true)
    ApplicationNotificationsMailer.stubs(:proof_received).returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :id_proof_attached,
      recipient: @constituent,
      actor: @constituent,
      notifiable: @application,
      metadata: { proof_type: 'id' },
      channel: :email
    )

    assert_not_nil notification
    assert_equal 'letter', notification.reload.metadata['actual_delivery_channel']
    assert_equal 'preference', notification.metadata['delivery_route_reason']
  end

  test 'training_rescheduled routes session and notification metadata to training mailer' do
    trainer = create(:trainer)
    training_session = create(:training_session, application: @application, trainer: trainer)
    mail_delivery = mock('mail_delivery')
    mail_delivery.expects(:deliver_later).returns(true)
    TrainingSessionNotificationsMailer.expects(:training_rescheduled)
                                      .with(training_session, instance_of(Notification))
                                      .returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :training_rescheduled,
      recipient: @constituent,
      actor: trainer,
      notifiable: training_session,
      metadata: { old_scheduled_for: 1.day.ago.iso8601 },
      channel: :email
    )

    assert_not_nil notification
    assert_equal 'email', notification.reload.metadata['actual_delivery_channel']
  end
end
