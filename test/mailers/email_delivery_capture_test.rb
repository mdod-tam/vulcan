# frozen_string_literal: true

require 'test_helper'

class EmailDeliveryCaptureTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  teardown { ENV['POSTMARK_SERVER_ID'] = @previous_server_id }

  setup do
    @previous_server_id = ENV.fetch('POSTMARK_SERVER_ID', nil)
    ENV['POSTMARK_SERVER_ID'] = '23'
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

  test 'vendor invoice delivery captures the vendor as recipient and owner despite a guardian relationship' do
    vendor = create(:vendor)
    create(:guardian_relationship, guardian_user: @user, dependent_user: vendor)
    invoice = create(:invoice, vendor: vendor)
    load_seeded_email_templates('vendor_notifications_invoice_generated')
    @transport.expects(:post).once.returns(@response)

    mail = VendorNotificationsMailer.with(invoice: invoice).invoice_generated.deliver_now

    attempt = invoice.email_delivery_attempts.sole
    assert_equal [vendor.email], mail.to
    assert_equal vendor.email, attempt.destination
    assert_equal vendor.id, attempt.recipient_id
    assert_equal vendor.id, attempt.delivery_owner_id
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
  test 'a confirmed temporary refusal retries the same envelope then blocks replay' do
    refusal = stub(code: '503', body: { ErrorCode: 100, Message: 'Maintenance' }.to_json)
    @transport.expects(:post).twice.returns(refusal).then.returns(@response)
    job = UserMailer.with(user: @user).password_reset.deliver_later
    serialized = job.serialize
    clear_enqueued_jobs
    ActiveJob::Base.execute(serialized)
    attempt = EmailDeliveryAttempt.where(correlation_id: job.email_delivery_context['delivery_correlation_id']).sole
    assert_equal 'failed', attempt.state
    retry_job = enqueued_jobs.sole
    assert_equal 'EmailDelivery::MailDeliveryJob', retry_job['job_class']
    ActiveJob::Base.execute(retry_job)
    assert_equal 'accepted', attempt.reload.state
    assert_equal 'provider-accepted', attempt.provider_message_id
    ActiveJob::Base.execute(serialized)
    assert_equal 1, EmailDeliveryAttempt.where(correlation_id: attempt.correlation_id).count
  end

  test 'the certification wrapper retries without a stale local error panel' do
    application = create(:application, :in_progress, medical_provider_email: 'provider@example.test')
    notification = create(:notification, recipient: @admin, actor: @admin, notifiable: application, action: 'medical_certification_requested')
    refusal = stub(code: '429', body: { ErrorCode: 0, Message: 'Rate limited' }.to_json)
    @transport.expects(:post).twice.returns(refusal).then.returns(@response)
    job = MedicalCertificationEmailJob.perform_later(application_id: application.id, timestamp: Time.current.iso8601, notification_id: notification.id)
    clear_enqueued_jobs
    ActiveJob::Base.execute(job.serialize)
    assert_equal 'failed', notification.email_delivery_attempts.sole.state
    ActiveJob::Base.execute(enqueued_jobs.sole)
    assert_equal 'accepted', notification.email_delivery_attempts.sole.state
    assert_not notification.reload.local_delivery_outcome?
  end

  test 'a timeout remains unknown and a repeated job cannot send again' do
    @transport.expects(:post).once.raises(Timeout::Error)
    job = UserMailer.with(user: @user).password_reset.deliver_later
    serialized = job.serialize
    clear_enqueued_jobs
    assert_raises(Postmark::TimeoutError) { ActiveJob::Base.execute(serialized) }
    assert_equal 'unknown', EmailDeliveryAttempt.order(:id).last.state
    ActiveJob::Base.execute(serialized)
    assert_empty enqueued_jobs
  end

  test 'an ambiguous HTTP 500 is not automatically retried' do
    @transport.expects(:post).once.returns(stub(code: '500', body: { ErrorCode: 101, Message: 'Internal error' }.to_json))
    job = UserMailer.with(user: @user).password_reset.deliver_later
    clear_enqueued_jobs
    assert_raises(Postmark::InternalServerError) { ActiveJob::Base.execute(job.serialize) }
    assert_equal 'unknown', EmailDeliveryAttempt.order(:id).last.state
    assert_empty enqueued_jobs
  end

  test 'a missing or blank server ID fails before recording or handing off a message' do
    @transport.expects(:post).never
    [nil, ''].each do |value|
      ENV['POSTMARK_SERVER_ID'] = value
      assert_no_difference 'EmailDeliveryAttempt.count' do
        assert_raises(EmailDelivery::ConfigurationError) { UserMailer.with(user: @user).password_reset.deliver_now }
      end
    end
  end

  test 'retry does not reroute a refused envelope to a changed destination' do
    refusal = stub(code: '503', body: { ErrorCode: 100, Message: 'Maintenance' }.to_json)
    @transport.expects(:post).once.returns(refusal)
    job = UserMailer.with(user: @user).password_reset.deliver_later
    clear_enqueued_jobs
    ActiveJob::Base.execute(job.serialize)
    attempt = EmailDeliveryAttempt.order(:id).last
    original = @user.email
    @user.update!(email: 'replacement@example.test')
    ActiveJob::Base.execute(enqueued_jobs.sole)
    assert_equal original, attempt.reload.destination
    assert_equal 'failed', attempt.state
  end

  test 'automatic retries stop after three confirmed refusals and retain the failure' do
    refusal = stub(code: '503', body: { ErrorCode: 100, Message: 'Maintenance' }.to_json)
    @transport.expects(:post).times(3).returns(refusal)
    job = UserMailer.with(user: @user).password_reset.deliver_later.serialize
    clear_enqueued_jobs
    2.times do
      ActiveJob::Base.execute(job)
      job = enqueued_jobs.sole
      clear_enqueued_jobs
    end
    assert_raises(EmailDelivery::RetryableFailure) { ActiveJob::Base.execute(job) }
    assert_empty enqueued_jobs
    attempt = EmailDeliveryAttempt.order(:id).last
    assert_equal 'failed', attempt.state
    assert_equal 1, EmailDeliveryAttempt.where(correlation_id: attempt.correlation_id).count
  end
end
