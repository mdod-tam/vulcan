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

  test 'notification creation diagnostics omit private exception details from logs and instrumentation' do
    invalid_record = User.new
    invalid_record.errors.add(:base, 'Private Patient private-notification@example.test at 410-555-0199')
    error = ActiveRecord::RecordInvalid.new(invalid_record)
    error.set_backtrace(['private-notification@example.test/410-555-0199.rb:1:in failure'])
    Notification.stubs(:create!).raises(error)
    messages = []
    payloads = []
    subscriber = ->(*args) { payloads << args.last }

    ActiveSupport::Notifications.subscribed(subscriber, 'notification_service.error') do
      Rails.logger.stub(:error, ->(message) { messages << message }) do
        assert_no_difference 'Notification.count' do
          assert_difference -> { Event.where(action: 'notification_creation_failed', auditable: @application).count }, 1 do
            assert_raises(ActiveRecord::RecordInvalid) do
              NotificationService.create_and_deliver!(type: :account_created, recipient: @constituent, actor: @admin,
                                                      notifiable: @application)
            end
          end
        end
      end
    end

    assert_equal 'ActiveRecord::RecordInvalid', payloads.sole[:error_class]
    assert_not payloads.sole.key?(:error)
    [messages.join, payloads.to_json].each do |diagnostics|
      %w[Private private-notification@example.test 410-555-0199].each do |private_value|
        assert_not_includes diagnostics, private_value
      end
    end
    assert_includes messages.join, 'ActiveRecord::RecordInvalid'
  end

  test 'notification boundary failure logs use recipient identity without inspecting personal fields' do
    error = StandardError.new('Private Patient private-boundary@example.test at 410-555-0199')
    NotificationService.stubs(:new).raises(error)
    messages = []

    Rails.logger.stub(:error, ->(message) { messages << message }) do
      assert_raises(StandardError) do
        NotificationService.create_and_deliver!(type: :account_created, recipient: @constituent)
      end
    end
    assert_includes messages.join, "recipient_id: #{@constituent.id}"
    assert_includes messages.join, 'StandardError'
    ['Private Patient', 'private-boundary@example.test', '410-555-0199', @constituent.email, @constituent.phone].each do |private_value|
      assert_not_includes messages.join, private_value
    end
  end

  test 'delivery_outcome never reports a returned record as delivered' do
    notification = create(:notification, recipient: @constituent)

    assert_equal :failed, NotificationService.delivery_outcome(nil)
    assert_equal :recorded, NotificationService.delivery_outcome(notification)
    {
      'queued' => :queued, 'submitted' => :submitted, 'delivered' => :delivered, 'opened' => :opened,
      'suppressed' => :suppressed, 'error' => :failed
    }.each do |status, outcome|
      notification.delivery_status = status

      assert_equal outcome, NotificationService.delivery_outcome(notification), status
    end
  end

  test 'create_and_deliver! creates a notification and enqueues an email job for deliverable actions' do
    assert_enqueued_jobs 1, only: EmailDelivery::MailDeliveryJob do
      notification = nil
      assert_no_difference 'Event.count' do
        assert_difference 'Notification.count', 1 do
          notification = NotificationService.create_and_deliver!(
            type: :account_created,
            recipient: @constituent,
            actor: @admin,
            notifiable: @application,
            metadata: {
              workflow: 'registration'
            },
            channel: :email,
            audit: true
          )
        end
      end

      assert_not_nil notification
      assert_predicate notification, :audited?
      assert_equal 'account_created', notification.action
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
    assert_no_enqueued_jobs only: EmailDelivery::MailDeliveryJob do
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

  test 'disability certification approval notifications are record-only delivery noops' do
    assert_no_enqueued_jobs only: EmailDelivery::MailDeliveryJob do
      notification = NotificationService.create_and_deliver!(
        type: :disability_certification_approved,
        recipient: @constituent,
        actor: @admin,
        notifiable: @application,
        channel: :email
      )

      assert_not_nil notification
      notification.reload
      assert_equal 'disability_certification_approved', notification.action
      assert_equal 'none', notification.metadata['actual_delivery_channel']
      assert_equal 'no_email_action', notification.metadata['delivery_route_reason']
      assert_nil notification.delivery_status
    end
  end

  test 'create_and_deliver! does NOT create an Event record directly' do
    # Audit events come from the callers of NotificationService, not from NotificationService itself.
    notification = nil
    assert_no_difference 'Event.count' do
      notification = NotificationService.create_and_deliver!(
        type: :proof_approved,
        recipient: @constituent,
        actor: @admin,
        notifiable: @application
      )
    end
    assert_predicate notification, :persisted?
    assert_not_predicate notification, :audited?
  end

  test 'audited record-only creation writes once without events, dispatch, or enqueue' do
    EmailDelivery::NotificationDispatch.expects(:new).never
    notification = nil
    assert_no_enqueued_jobs do
      assert_no_difference 'Event.count' do
        assert_difference 'Notification.count', 1 do
          notification = NotificationService.create_and_deliver!(type: :account_created, recipient: @constituent, actor: @admin,
                                                                 notifiable: @application, audit: true, deliver: false)
        end
      end
    end
    assert_predicate notification, :persisted?
    assert_predicate notification, :audited?
    assert_nil notification.delivery_status
    assert_nil notification.metadata['actual_delivery_channel']
  end

  test 'string option keys normalize once with actor and metadata preserved' do
    notification = NotificationService.create_and_deliver!(type: :account_created, recipient: @constituent,
                                                           **{ 'actor' => @admin, 'notifiable' => @application, 'channel' => ' LETTER ', 'deliver' => false,
                                                               'audit' => false, 'metadata' => { workflow: 'registration' } })
    assert_equal @admin, notification.actor
    assert_not_predicate notification, :audited?
    assert_equal 'letter', notification.metadata['channel']
    assert_equal 'registration', notification.metadata['workflow']
  end

  test 'missing actors never select an unrelated administrator or support account' do
    create(:constituent, email: ProgramContact.support_email)
    assert_no_difference 'Notification.count' do
      assert_raises(ArgumentError) do
        NotificationService.create_and_deliver!(type: :account_created, recipient: @constituent,
                                                notifiable: @application, deliver: false)
      end
    end
  end

  test 'mailer failure records a safe local outcome through the notification owner' do
    diagnostic = 'SMTP auth error for https://example.test/request/secret-token'
    ApplicationNotificationsMailer.stubs(:account_created).raises(Net::SMTPAuthenticationError, diagnostic)

    notification = NotificationService.create_and_deliver!(
      type: :account_created, recipient: @constituent, actor: @admin, notifiable: @application,
      metadata: { workflow: 'registration' }, channel: :email
    )

    notification.reload
    assert_equal 'error', notification.delivery_status
    assert_equal 'Email could not be sent.', notification.email_error_message
    assert_equal 'Net::SMTPAuthenticationError', notification.metadata.dig('delivery_error', 'error_class')
    assert_equal 'email', notification.metadata.dig('delivery_error', 'channel')
    assert_equal 'registration', notification.metadata['workflow']
    assert_equal 'none', notification.metadata['actual_delivery_channel']
    assert_equal 'email_delivery_failed', notification.metadata['delivery_route_reason']
    assert_not_includes notification.metadata.to_json, 'secret-token'
  end

  test 'creation failures propagate with a durable safe failure audit' do
    invalid = Notification.new
    invalid.errors.add(:notifiable, :invalid)
    Notification.expects(:create!).once.raises(ActiveRecord::RecordInvalid.new(invalid))
    @application.expects(:reload).never

    Rails.logger.expects(:error).at_least_once

    assert_raises(ActiveRecord::RecordInvalid) do
      NotificationService.create_and_deliver!(type: :proof_approved, recipient: @constituent, actor: @admin, notifiable: @application)
    end
    event = Event.find_by!(action: 'notification_creation_failed', auditable: @application)
    assert_equal @admin.id, event.user_id
    assert_equal @constituent.id, event.metadata['recipient_id']
    assert_equal 'ActiveRecord::RecordInvalid', event.metadata['error_class']
  end

  test 'notification failure rolls back a caller transaction rather than reporting a committed success' do
    invalid = Notification.new
    invalid.errors.add(:recipient, :invalid)
    Notification.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(invalid))
    before = @application.application_date

    assert_no_difference -> { Event.where(action: 'notification_creation_failed', auditable: @application).count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        ApplicationRecord.transaction do
          @application.update!(application_date: 1.day.ago)
          NotificationService.create_and_deliver!(type: :proof_approved, recipient: @constituent, actor: @admin,
                                                  notifiable: @application, deliver: false)
        end
      end
    end
    assert_equal before, @application.reload.application_date
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

  test 'proof rejection delivery belongs exclusively to the secure request command' do
    ApplicationNotificationsMailer.expects(:proof_rejected).never

    NotificationService::PROOF_REJECTION_ACTIONS.each do |action|
      assert_no_difference 'Notification.count' do
        assert_raises(ArgumentError) do
          NotificationService.create_and_deliver!(type: action, recipient: @constituent, actor: @admin, notifiable: @application)
        end
      end
    end
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

  test 'security key recovery approval records email-only delivery even for letter preference' do
    @constituent.update!(
      communication_preference: 'letter',
      physical_address_1: '123 Main St',
      city: 'Baltimore',
      state: 'MD',
      zip_code: '21201'
    )
    recovery_request = create(:recovery_request, user: @constituent)
    mail_delivery = mock('mail_delivery')
    mail_delivery.expects(:deliver_later).returns(true)
    ApplicationNotificationsMailer.expects(:security_key_recovery_approved)
                                  .with(recovery_request, instance_of(Notification))
                                  .returns(mail_delivery)

    notification = NotificationService.create_and_deliver!(
      type: :security_key_recovery_approved,
      recipient: @constituent,
      actor: @admin,
      notifiable: recovery_request,
      channel: :email
    )

    assert_not_nil notification
    assert_equal 'email', notification.reload.metadata['actual_delivery_channel']
    assert_equal 'email_only', notification.metadata['delivery_route_reason']
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
