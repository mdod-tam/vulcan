# frozen_string_literal: true

require 'test_helper'

class DisabilityCertificationFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    create_certifying_professional_email_templates

    # Timestamped emails prevent uniqueness errors.
    timestamp = Time.current.to_i
    @admin = create(:admin, email: "mcf_admin_#{timestamp}@example.com")
    @constituent = create(:constituent, email: "mcf_constituent_#{timestamp}@example.com")
    @application = create(:application,
                          user: @constituent,
                          certifying_professional_name: 'Dr. Smith',
                          certifying_professional_email: "drsmith_#{timestamp}@example.com",
                          certifying_professional_phone: '555-555-5555')

    sign_in_for_integration_test(@admin)
  end

  def test_full_certification_request_flow
    get admin_application_path(@application)
    assert_response :success

    assert_enqueued_with(job: DisabilityCertificationEmailJob) do
      post resend_disability_certification_admin_application_path(@application)
    end

    assert_redirected_to admin_application_path(@application)
    assert_equal 'Certification request sent successfully.', flash[:notice]
    # follow_redirect! does not use default_headers, so pass the test user header.
    follow_redirect!(headers: { 'X-Test-User-Id' => @admin.id.to_s })

    @application.reload
    assert_equal 'requested', @application.disability_certification_status
    assert_equal 1, @application.disability_certification_request_count

    notification = Notification.last
    assert_not_nil notification, 'Expected notification to be created but was nil'
    assert_equal 'disability_certification_requested', notification.action
    assert_equal @application.user.id, notification.recipient_id
    assert_equal @admin.id, notification.actor_id
    assert_nil notification.metadata&.dig('delivery_error', 'message')

    perform_enqueued_jobs
    assert_emails 1

    # A second request gives the page a request history.
    post resend_disability_certification_admin_application_path(@application)
    @application.reload
    assert_equal 2, @application.disability_certification_request_count

    get admin_application_path(@application)
    assert_response :success

    assert_select '.history-item', minimum: 2

    assert_match(/Disability Certification/, response.body)
  end

  def test_constituent_portal_view
    delete sign_out_path

    sign_in_for_integration_test(@constituent)

    # The admin sends the request before the constituent views it.
    sign_in_for_integration_test(@admin)
    post resend_disability_certification_admin_application_path(@application)
    sign_out

    sign_in_for_integration_test(@constituent)

    get constituent_portal_application_path(@application)
    assert_response :success

    @application.reload
    assert_equal 'requested', @application.disability_certification_status

    assert_select 'h2', text: /Disability Certification/

    assert_match(/Requested/, response.body)
    assert_match(/Certification Status/, response.body)
  end

  def test_handling_errors_gracefully
    application_without_email = @application

    # update_columns skips validations, so the provider email can be nil.
    application_without_email.update_columns(certifying_professional_email: nil)

    post resend_disability_certification_admin_application_path(application_without_email)
    assert_redirected_to admin_application_path(application_without_email)
    assert_match(/Failed to process certification request/, flash[:alert])

    assert_no_enqueued_jobs only: DisabilityCertificationEmailJob

    assert_no_difference 'Notification.count' do
      application_without_email
    end
  end

  def teardown
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
  end

  private

  def create_certifying_professional_email_templates
    return if EmailTemplate.exists?(name: 'certifying_professional_request_certification', format: :text, locale: 'en')

    EmailTemplate.create!(
      name: 'certifying_professional_request_certification',
      format: :text,
      locale: 'en',
      subject: 'Disability Certification Request',
      body: "Dear Certifying Professional,\n\n" \
            "We need disability certification for %<constituent_full_name>s.\n\n" \
            "Application ID: %<application_id>s\n" \
            "Date: %<timestamp_formatted>s\n" \
            "DOB: %<constituent_dob_formatted>s\n" \
            "Phone: %<constituent_phone_formatted>s\n" \
            "Email: %<constituent_email>s\n" \
            "Address: %<constituent_address_formatted>s\n\n" \
            "%<request_count_message>s\n\n" \
            "Download form: %<download_form_url>s\n\n" \
            "Please provide the required certification.\n\n" \
            'Thank you.',
      description: 'Sent to certifying professionals requesting certification.'
    )
  end
end
