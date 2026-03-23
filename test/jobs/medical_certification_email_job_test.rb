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

  test 'fallback notification creation does not trigger delivery error and still sends email' do
    timestamp = Time.current.iso8601

    assert_difference "Notification.where(action: 'medical_certification_requested').count", 1 do
      assert_emails 1 do
        MedicalCertificationEmailJob.perform_now(
          application_id: @application.id,
          timestamp: timestamp
        )
      end
    end

    notification = Notification.where(action: 'medical_certification_requested', notifiable: @application)
                               .order(created_at: :desc)
                               .first

    assert_not_nil notification
    assert notification.recipient.admin?
    assert_equal notification.recipient, notification.actor
    assert_equal 'email', notification.metadata['channel']
    assert_nil notification.delivery_status
    assert_nil notification.metadata&.dig('delivery_error', 'message')
  end

  private

  def ensure_request_certification_template!
    EmailTemplate.find_or_create_by!(name: 'medical_provider_request_certification', format: :text) do |template|
      template.subject = 'Medical Certification Request for %<constituent_full_name>s'
      template.body = <<~TEXT
        Please complete the requested certification for %<constituent_full_name>s.
        Request: %<request_count_message>s
        Timestamp: %<timestamp_formatted>s
        DOB: %<constituent_dob_formatted>s
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
          constituent_address_formatted
          application_id
          download_form_url
        ],
        'optional' => []
      }
      template.version = 1
    end
  end
end
