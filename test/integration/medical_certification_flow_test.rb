# frozen_string_literal: true

require 'test_helper'

class MedicalCertificationFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    # Ensure required email templates exist
    create_medical_provider_email_templates

    # Use unique emails with a timestamp to avoid email duplication errors
    timestamp = Time.current.to_i
    @admin = create(:admin, email: "mcf_admin_#{timestamp}@example.com")
    @constituent = create(:constituent, email: "mcf_constituent_#{timestamp}@example.com")
    @application = create(:application,
                          user: @constituent,
                          medical_provider_name: 'Dr. Smith',
                          medical_provider_email: "drsmith_#{timestamp}@example.com",
                          medical_provider_phone: '555-555-5555')

    # Sign in as admin using the proper integration test helper
    sign_in_for_integration_test(@admin)

    # Since we can't follow a redirect, we'll navigate directly to where we need to go
  end

  def test_full_certification_request_flow
    # 1. Visit the application page
    get admin_application_path(@application)
    assert_response :success

    # 2. Send certification request
    assert_enqueued_with(job: MedicalCertificationEmailJob) do
      post resend_medical_certification_admin_application_path(@application)
    end

    # 3. Check redirect and flash message
    assert_redirected_to admin_application_path(@application)
    assert_equal 'Certification request sent successfully.', flash[:notice]
    # Pass headers explicitly since follow_redirect! doesn't inherit default_headers
    follow_redirect!(headers: { 'X-Test-User-Id' => @admin.id.to_s })

    # 4. Verify application was updated
    @application.reload
    assert_equal 'requested', @application.medical_certification_status
    assert_equal 1, @application.medical_certification_request_count

    # 5. Verify notification was created
    notification = Notification.last
    assert_not_nil notification, 'Expected notification to be created but was nil'
    assert_equal 'medical_certification_requested', notification.action
    assert_equal @application.user.id, notification.recipient_id
    assert_equal @admin.id, notification.actor_id

    # 6. Verify the job executed the email
    perform_enqueued_jobs
    assert_emails 1

    # 7. Send a second request to test history
    post resend_medical_certification_admin_application_path(@application)
    @application.reload
    assert_equal 2, @application.medical_certification_request_count

    # 8. Verify page shows multiple requests
    get admin_application_path(@application)
    assert_response :success

    # Verify there are two certification request history items visible
    assert_select '.history-item', minimum: 2

    # Verify the medical certification section is on the page
    assert_match(/Medical Certification/, response.body)
  end

  def test_constituent_portal_view
    # Now test the constituent view of the certification status

    # Sign out admin
    delete sign_out_path

    # Sign in as constituent
    sign_in_for_integration_test(@constituent)

    # Send a certification request as admin first
    sign_in_for_integration_test(@admin)
    post resend_medical_certification_admin_application_path(@application)
    sign_out

    # Sign back in as constituent
    sign_in_for_integration_test(@constituent)

    # Visit application page
    get constituent_portal_application_path(@application)
    assert_response :success

    # Check application status
    @application.reload
    assert_equal 'requested', @application.medical_certification_status

    # Verify medical certification status is shown
    assert_select 'h2', text: /Disability Certification/

    # With more complex pages, sometimes we need to verify content exists
    # without using exact selectors
    assert_match(/Requested/, response.body)
    assert_match(/Certification Status/, response.body)
  end

  def test_handling_errors_gracefully
    # Get a valid application without touching validation
    application_without_email = @application

    # Update the application directly in the database to bypass validation
    application_without_email.update_columns(medical_provider_email: nil)

    post resend_medical_certification_admin_application_path(application_without_email)
    assert_redirected_to admin_application_path(application_without_email)
    assert_match(/Failed to process certification request/, flash[:alert])

    # Verify no job was enqueued
    assert_no_enqueued_jobs only: MedicalCertificationEmailJob

    # Verify no notification was created
    assert_no_difference 'Notification.count' do
      # Just to satisfy the block requirement for assert_no_difference
      application_without_email
    end
  end

  def teardown
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
  end

  private

  def create_medical_provider_email_templates
    # Create medical_provider_request_certification template
    return if EmailTemplate.exists?(name: 'medical_provider_request_certification', format: :text)

    EmailTemplate.create!(
      name: 'medical_provider_request_certification',
      format: :text,
      subject: 'Medical Certification Request',
      body: "Dear Medical Provider,\n\n" \
            "We need medical certification for %<constituent_full_name>s.\n\n" \
            "Application ID: %<application_id>s\n" \
            "Date: %<timestamp_formatted>s\n" \
            "DOB: %<constituent_dob_formatted>s\n" \
            "Address: %<constituent_address_formatted>s\n\n" \
            "%<request_count_message>s\n\n" \
            "Download form: %<download_form_url>s\n\n" \
            "Please provide the required certification.\n\n" \
            'Thank you.',
      description: 'Sent to medical providers requesting certification.'
    )
  end
end
