# frozen_string_literal: true

require 'test_helper'

class EmailDeliveryCaptureTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = create(:constituent, communication_preference: 'email')
    @admin = create(:admin)
    load_seeded_email_templates('user_mailer_password_reset', 'application_notifications_provider_info_requested', 'medical_provider_request_certification')
    @old_method = ApplicationMailer.delivery_method
    ApplicationMailer.delivery_method = :postmark
    @transport = mock('offline Postmark HTTP transport')
    Postmark::HttpClient.any_instance.stubs(:build_http).returns(@transport)
    @response = stub(code: '200', body: { MessageID: 'provider-accepted', SubmittedAt: Time.current.iso8601, ErrorCode: 0, Message: 'OK' }.to_json)
    EmailDelivery::Current.reset
  end

  teardown do
    ApplicationMailer.delivery_method = @old_method
    EmailDelivery::Current.reset
  end

  test 'synchronous send records provider identity distinct from RFC identity and destination' do
    @transport.expects(:post).once.returns(@response)
    mail = UserMailer.with(user: @user).password_reset.deliver_now
    attempt = EmailDeliveryAttempt.order(:id).last
    assert_equal 'provider-accepted', attempt.provider_message_id
    assert_equal mail.message_id, attempt.rfc_message_id
    assert_not_equal attempt.provider_message_id, attempt.rfc_message_id
    assert_equal @user.email, attempt.destination
    assert_equal @user.id, attempt.delivery_owner_id
    assert attempt.accepted_at
  end

  test 'queued context keeps logical identity across a second job execution' do
    @transport.expects(:post).once.returns(@response)
    job = UserMailer.with(user: @user).password_reset.deliver_later
    serialized = job.serialize
    2.times { ActiveJob::Base.execute(serialized) }
    attempt = EmailDeliveryAttempt.where(correlation_id: job.email_delivery_context.fetch('delivery_correlation_id')).sole
    assert_equal 'provider-accepted', attempt.provider_message_id
  end

  test 'provider acceptance with local save failure does not revoke the live secure link' do
    @transport.expects(:post).once.returns(@response)
    EmailDeliveryAttempt.any_instance.stubs(:update!).raises(ActiveRecord::StatementInvalid, 'local write unavailable')
    application = create(:application, :in_progress, user: @user)
    result = Applications::RequestProviderInfo.new(application: application, actor: @admin).call
    assert result.success?, result.message
    form = result.data.fetch(:secure_request_forms).first.reload
    assert_predicate form, :active?
    attempt = EmailDeliveryAttempt.find_by!(origin: form)
    assert_equal 'unknown', attempt.state
    assert_nil attempt.accepted_at
  end

  test 'notification bookkeeping failure after sending does not revoke a secure link' do
    @transport.expects(:post).once.returns(@response)
    Notification.any_instance.stubs(:record_delivery_handoff!).raises(ActiveRecord::StatementInvalid, 'tracking unavailable')
    application = create(:application, :in_progress, user: @user)
    result = Applications::RequestProviderInfo.new(application: application, actor: @admin).call
    assert result.success?, result.message
    form = result.data.fetch(:secure_request_forms).first.reload
    assert_predicate form, :active?
    assert EmailDeliveryAttempt.find_by!(origin: form).accepted_at
  end

  test 'certification wrapper job reaches the same acceptance owner' do
    application = create(:application, :in_progress, medical_provider_email: 'provider@example.test')
    notification = create(:notification, recipient: @admin, actor: @admin, notifiable: application, action: 'medical_certification_requested')
    @transport.expects(:post).once.returns(@response)
    MedicalCertificationEmailJob.perform_now(application_id: application.id, timestamp: Time.current.iso8601, notification_id: notification.id)
    attempt = notification.email_delivery_attempts.sole
    assert_equal application, attempt.origin
    assert_equal 'provider@example.test', attempt.destination
    assert_equal 'provider-accepted', attempt.provider_message_id
    assert_nil attempt.delivery_owner
  end

  test 'early feedback survives the actual provider acceptance callback' do
    @transport.expects(:post).once.with do |_uri, body, _headers|
      payload = JSON.parse(body)
      fact = EmailDelivery::Feedback.webhook('RecordType' => 'Delivery', 'MessageID' => 'provider-accepted',
                                             'Recipient' => @user.email, 'DeliveredAt' => Time.current.iso8601,
                                             'Metadata' => payload.fetch('Metadata'))
      assert_equal :applied, EmailDelivery::Feedback.apply(fact)
      true
    end.returns(@response)
    UserMailer.with(user: @user).password_reset.deliver_now
    attempt = EmailDeliveryAttempt.where(delivery_owner: @user).sole
    assert attempt.delivered_at
    assert attempt.accepted_at
    assert_equal 1, attempt.email_delivery_receipts.count
  end

  test 'failure before the durable attempt exists prevents provider handoff' do
    @transport.expects(:post).never
    EmailDeliveryAttempt.stubs(:create!).raises(ActiveRecord::StatementInvalid, 'local write unavailable')
    assert_raises(ActiveRecord::StatementInvalid) { UserMailer.with(user: @user).password_reset.deliver_now }
  end
end
