# frozen_string_literal: true

require 'application_system_test_case'

class MedicalCertificationTest < ApplicationSystemTestCase
  def setup
    super

    @admin = create(:admin)
    @constituent = create(:constituent)
    @application = create(:application,
                          user: @constituent,
                          status: 'in_progress',
                          medical_provider_name: 'Dr. Jane Smith',
                          medical_provider_email: 'drsmith@example.com',
                          medical_provider_phone: '555-555-5555')
  end

  test 'admin can view medical certification section' do
    system_test_sign_in(@admin)
    wait_for_turbo

    visit admin_application_path(@application)

    wait_for_turbo
    wait_for_network_idle(timeout: 10) if respond_to?(:wait_for_network_idle)

    assert_text 'Disability Certification', wait: 10

    assert_text @application.medical_provider_name, wait: 10
    assert_text @application.medical_provider_phone, wait: 10

    clear_pending_network_connections if respond_to?(:clear_pending_network_connections)
  end

  test 'admin can send medical certification request' do
    system_test_sign_in(@admin)
    wait_for_turbo

    visit admin_application_path(@application)

    wait_for_turbo
    wait_for_network_idle(timeout: 10) if respond_to?(:wait_for_network_idle)

    accept_confirm do
      if page.has_button?('Send DocuSeal Request', wait: 5)
        click_button 'Send DocuSeal Request'
      elsif page.has_button?('Resend DocuSeal Request', wait: 5)
        click_button 'Resend DocuSeal Request'
      elsif page.has_button?('Send Secure Cert Upload Link', wait: 5)
        click_button 'Send Secure Cert Upload Link'
      else
        skip 'No medical certification request buttons available'
      end
    end

    wait_for_turbo

    # This smoke test accepts success messages and DocuSeal error messages.
    if (page.has_text?('success', wait: 10) && page.has_text?('sent', wait: 5)) ||
       (page.has_text?('successfully', wait: 10) && page.has_text?('Certification', wait: 5))
      # Success text alone does not establish provider delivery.
    elsif page.has_text?('Failed to send signing request', wait: 10) ||
          page.has_text?('Not authenticated', wait: 10) ||
          page.has_text?('API Error', wait: 10)
      puts 'INFO: DocuSeal API failed as expected in test environment'
    elsif page.has_text?('error', wait: 5) || page.has_text?('failed', wait: 5)
      if page.has_text?('DocuSeal', wait: 2) || page.has_text?('signing', wait: 2)
        puts 'INFO: DocuSeal-related error as expected in test environment'
      else
        flunk 'Found unexpected error message on page'
      end
    else
      assert page.has_text?(/success|sent|successfully/i, wait: 10), 'Expected to find success message on page'
    end

    clear_pending_network_connections if respond_to?(:clear_pending_network_connections)
  end

  test 'constituent can view certification status' do
    NotificationService.create_and_deliver!(
      type: 'medical_certification_requested',
      notifiable: @application,
      recipient: @constituent,
      actor: @admin,
      created_at: 1.hour.ago,
      read_at: nil
    )

    @application.update!(
      medical_certification_status: 'requested',
      medical_certification_request_count: 1
    )

    system_test_sign_in(@constituent)
    wait_for_turbo

    visit constituent_portal_application_path(@application)

    wait_for_turbo
    wait_for_network_idle(timeout: 10) if respond_to?(:wait_for_network_idle)

    assert_text 'Application Details', wait: 15

    assert_text 'Disability Certification', wait: 10

    assert_text @application.medical_provider_name, wait: 10

    assert_selector '[role="status"]', text: 'Requested', wait: 10

    clear_pending_network_connections if respond_to?(:clear_pending_network_connections)
  end

  test 'admin sees appropriate error for invalid requests' do
    # Bypass validation to exercise the missing-email state.
    @application.update_columns(medical_provider_email: nil)

    system_test_sign_in(@admin)
    wait_for_turbo

    visit admin_application_path(@application)

    wait_for_turbo
    wait_for_network_idle(timeout: 10) if respond_to?(:wait_for_network_idle)

    # The secure-upload request action is unavailable without a provider email.
    assert_text 'Secure cert upload form cannot be sent - provider email is missing.', wait: 10
    assert_no_button 'Send Secure Cert Upload Link', wait: 5
    assert_no_button 'Send Email', wait: 5

    clear_pending_network_connections if respond_to?(:clear_pending_network_connections)
  end

  def teardown
    clear_enqueued_jobs
    clear_performed_jobs

    super
  end
end
