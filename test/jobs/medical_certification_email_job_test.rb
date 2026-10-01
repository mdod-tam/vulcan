# frozen_string_literal: true

require 'test_helper'

class MedicalCertificationEmailJobTest < ActiveJob::TestCase
  setup do
    ensure_request_certification_template!

    @admin = create(:admin)
    @constituent = create(:constituent, :with_address_and_phone)
    @application = create(:application,
                          user: @constituent,
                          medical_provider_name: 'Dr. Ada Lovelace',
                          medical_provider_email: 'provider@example.com')
  end

  test 'sends request certification email when notification id is provided' do
    timestamp = Time.current.iso8601
    notification = Notification.create!(
      recipient: @constituent,
      actor: @admin,
      action: 'medical_certification_requested',
      notifiable: @application,
      metadata: { 'timestamp' => timestamp, 'channel' => 'email' }
    )

    assert_no_difference 'Notification.count' do
      assert_emails 1 do
        MedicalCertificationEmailJob.perform_now(
          application_id: @application.id,
          timestamp: timestamp,
          notification_id: notification.id
        )
      end
    end

    notification.reload
    assert_nil notification.metadata['error_message']
    assert_nil notification.metadata&.dig('delivery_error', 'message')
  end

  test 'an unowned direct request does not invent a tracking recipient' do
    assert_no_difference 'Notification.count' do
      assert_no_emails do
        assert_raises(ArgumentError) do
          MedicalCertificationEmailJob.perform_now(application_id: @application.id, timestamp: Time.current.iso8601)
        end
      end
    end
  end

  test 'transport failure without a linked attempt records one safe notification outcome' do
    notification = Notification.create!(
      recipient: @constituent, actor: @admin, action: 'medical_certification_requested',
      notifiable: @application, metadata: { 'channel' => 'email', 'workflow' => 'preserved' }
    )
    diagnostic = 'Rejected https://example.test/request/secret-token'
    Mail::TestMailer.any_instance.expects(:deliver!).raises(StandardError, diagnostic)

    assert_raises(StandardError) do
      MedicalCertificationEmailJob.perform_now(application_id: @application.id, timestamp: Time.current.iso8601,
                                               notification_id: notification.id)
    end

    notification.reload
    assert_equal 'error', notification.delivery_status
    assert_equal 'Email could not be sent.', notification.email_error_message
    assert_equal 'StandardError', notification.metadata.dig('delivery_error', 'error_class')
    assert_equal 'preserved', notification.metadata['workflow']
    assert_equal 'none', notification.metadata['actual_delivery_channel']
    assert_equal 'email_delivery_failed', notification.metadata['delivery_route_reason']
    assert_empty notification.email_delivery_attempts
    assert_not_includes notification.metadata.to_json, 'secret-token'
  end

  private

  def ensure_request_certification_template!
    EmailTemplate.find_or_create_by!(name: 'medical_provider_request_certification', format: :text, locale: 'en') do |template|
      template.subject = 'Medical Certification Request for %<constituent_full_name>s'
      template.body = <<~TEXT
        Please complete the requested certification for %<constituent_full_name>s.
        Request: %<request_count_message>s
        Timestamp: %<timestamp_formatted>s
        DOB: %<constituent_dob_formatted>s
        Phone: %<constituent_phone_formatted>s
        Email: %<constituent_email>s
        Address: %<constituent_address_formatted>s
        Application ID: %<application_id>s
        Form URL: %<download_form_url>s
      TEXT
      template.description = 'Test template for medical provider request certification emails.'
      template.variables = {
        'required' => %w[
          constituent_full_name
          request_count_message
          timestamp_formatted
          constituent_dob_formatted
          constituent_phone_formatted
          constituent_email
          constituent_address_formatted
          application_id
          download_form_url
        ],
        'optional' => []
      }
      template.version = 1
    end
  end
  test 'a certification email queued before an off and on interval is suppressed, not retried' do
    notification = Notification.create!(
      recipient: @constituent, actor: @admin, action: 'medical_certification_requested',
      notifiable: @application, metadata: { 'channel' => 'email' }
    )
    MedicalCertificationEmailJob.perform_later(application_id: @application.id, timestamp: Time.current.iso8601,
                                               notification_id: notification.id)
    EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: false, actor: @admin, operation_id: 'op-1')
    EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: true, actor: @admin, operation_id: 'op-2')

    assert_no_emails do
      assert_nothing_raised { perform_enqueued_jobs(only: MedicalCertificationEmailJob) }
    end

    assert_equal 'pending_canceled', notification.reload.metadata.dig('delivery_suppressed', 'reason')
    assert_equal 'suppressed', notification.delivery_status
  end
end
