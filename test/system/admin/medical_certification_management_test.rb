# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  # This is a consolidated test file for managing medical certifications in the admin panel.
  # It covers UI states, approval/rejection workflows, and validation, combining the
  # responsibilities of several older, redundant test files.
  class MedicalCertificationManagementTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      # Create a base application that can be modified by each test
      @application = create(:application,
                            status: 'in_progress',
                            medical_certification_status: 'not_requested', # Start from a neutral state
                            medical_provider_name: 'Dr. Test Provider',
                            medical_provider_email: 'provider@example.com')

      # Sign in as admin using system test helper
      system_test_sign_in(@admin)
    end

    # --- UI State Tests ---

    test 'upload form is shown when certification is requested' do
      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)

      assert_selector '[data-testid="medical-certification-upload-form"]', text: 'Upload Medical Certification'
      assert_no_text 'View Medical Certification Document'
      assert_no_button 'Review Certification'
    end

    test 'review actions are shown when certification is received' do
      # Simulate a received certification
      @application.medical_certification.attach(io: StringIO.new('test content'), filename: 'cert.pdf', content_type: 'application/pdf')
      @application.update!(medical_certification_status: 'received')
      visit admin_application_path(@application)

      assert_no_selector '[data-testid="medical-certification-upload-form"]'
      assert_button 'Review Certification'
    end

    test 'view link is shown when certification is approved' do
      # Simulate an approved certification
      @application.medical_certification.attach(io: StringIO.new('test content'), filename: 'cert.pdf', content_type: 'application/pdf')
      @application.update!(medical_certification_status: 'approved')
      visit admin_application_path(@application)

      assert_no_selector '[data-testid="medical-certification-upload-form"]'
      assert_link 'View Medical Certification Document'
    end

    # --- Functional Tests ---

    test 'admin can approve a medical certification during upload' do
      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)

      # Wait for page to be fully loaded
      wait_for_turbo

      # Ensure the form is present before interacting
      assert_selector '[data-testid="medical-certification-upload-form"]', wait: 10

      within '[data-testid="medical-certification-upload-form"]' do
        choose 'Approve Certification and Upload'
        attach_file 'medical_certification', Rails.root.join('test/fixtures/files/medical_certification_valid.pdf')
        click_button 'Process Certification'
      end

      # Wait for form submission to complete
      wait_for_turbo

      assert_text 'Medical certification successfully uploaded and approved', wait: 10
      @application.reload
      assert @application.medical_certification.attached?, 'Medical certification file should be attached'
      assert_equal 'approved', @application.medical_certification_status
      assert_audit_event('medical_certification_status_changed', actor: @admin, auditable: @application)

      # Clear any pending network connections to prevent timeout during teardown
      clear_pending_network_connections if respond_to?(:clear_pending_network_connections)
    end

    test 'admin can reject a medical certification without uploading' do
      RejectionReason.find_or_create_by!(
        code: 'missing_signature',
        proof_type: 'medical_certification',
        locale: 'en'
      ) do |reason|
        reason.body = 'The disability certification is missing the required signature.'
      end

      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)

      # Wait for page to be fully loaded
      wait_for_turbo

      # Ensure the form is present before interacting
      assert_selector '[data-testid="medical-certification-upload-form"]', wait: 10

      within '[data-testid="medical-certification-upload-form"]' do
        choose 'Reject Certification'
        assert_selector 'select[name="rejection_reason_code"]', visible: true, wait: 5
        select 'Missing Signature', from: 'rejection_reason_code'
        click_button 'Process Certification'
      end

      # Wait for form submission to complete
      wait_for_turbo

      assert_text 'Medical certification rejected and provider notified', wait: 10
      @application.reload
      assert_equal 'rejected', @application.medical_certification_status
      assert_equal 'The disability certification is missing the required signature.', @application.medical_certification_rejection_reason
      assert_audit_event('medical_certification_status_changed', actor: @admin, auditable: @application)

      # Clear any pending network connections to prevent timeout during teardown
      clear_pending_network_connections if respond_to?(:clear_pending_network_connections)
    end

    test 'selecting Other when rejecting during upload reveals the custom certification reason field' do
      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)

      wait_for_turbo
      assert_selector '[data-testid="medical-certification-upload-form"]', wait: 10

      within '[data-testid="medical-certification-upload-form"]' do
        choose 'Reject Certification'
        select 'Other (custom reason)', from: 'rejection_reason_code'

        assert_selector '#cert-custom-reason-area', visible: true

        custom_reason = find("textarea[name='medical_certification_rejection_reason']", visible: true)
        assert_nil custom_reason[:disabled], 'Custom certification reason should be enabled after selecting Other'
        assert_selector 'label[for="medical_certification_rejection_reason"]', text: 'Custom Rejection Reason'
      end
    end

    # --- Validation Tests ---

    test 'admin sees error when trying to approve without a file' do
      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)

      # Wait for page to be fully loaded
      wait_for_turbo

      # Ensure the form is present before interacting
      assert_selector '[data-testid="medical-certification-upload-form"]', wait: 10

      within '[data-testid="medical-certification-upload-form"]' do
        # Select the "Approve" option
        choose 'Approve Certification and Upload'

        # Try to submit without attaching a file
        click_button 'Process Certification'
      end

      # Wait for any request processing to complete
      wait_for_turbo

      # Verify error message is displayed
      assert_text 'Please select a file to upload', wait: 10

      # Verify status remained 'requested'
      @application.reload
      assert_equal 'requested', @application.medical_certification_status

      # Clear any pending network connections to prevent timeout during teardown
      clear_pending_network_connections if respond_to?(:clear_pending_network_connections)
    end

    test 'admin sees error when trying to reject without a reason' do
      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)

      # Wait for page to be fully loaded
      wait_for_turbo

      # Ensure the form is present before interacting
      assert_selector '[data-testid="medical-certification-upload-form"]', wait: 10

      within '[data-testid="medical-certification-upload-form"]' do
        # Select the "Reject" option
        choose 'Reject Certification'

        # Try to submit without selecting a rejection reason
        click_button 'Process Certification'
      end

      # Wait for any request processing to complete
      wait_for_turbo

      # Verify error message is displayed
      assert_text 'Please select a rejection reason', wait: 10

      # Verify status remained 'requested'
      @application.reload
      assert_equal 'requested', @application.medical_certification_status

      # Clear any pending network connections to prevent timeout during teardown
      clear_pending_network_connections if respond_to?(:clear_pending_network_connections)
    end

    test 'upload form is not shown when medical certification is already attached' do
      # Prepare an application that already has a certification attached
      @application.medical_certification.attach(
        io: StringIO.new('test content'),
        filename: 'already_attached.pdf',
        content_type: 'application/pdf'
      )
      @application.update(medical_certification_status: 'received')

      visit admin_application_path(@application)

      # Verify upload form is not shown
      assert_no_selector '[data-testid="medical-certification-upload-form"]'

      # But the link to view the certification is shown
      assert_text 'View Medical Certification Document'
    end
  end
end
