# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class MedicalCertificationManagementTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      @application = create(:application,
                            status: 'in_progress',
                            medical_certification_status: 'not_requested',
                            medical_provider_name: 'Dr. Test Provider',
                            medical_provider_email: 'provider@example.com')

      system_test_sign_in(@admin)
    end

    # Certification UI states

    test 'upload form is shown when certification is requested' do
      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)

      assert_selector '[data-testid="medical-certification-upload-form"]', text: 'Upload Disability Certification'
      assert_no_text 'View Medical Certification Document'
      assert_no_button 'Review Certification'
    end

    test 'review actions are shown when certification is received' do
      @application.medical_certification.attach(io: StringIO.new('test content'), filename: 'cert.pdf', content_type: 'application/pdf')
      @application.update!(medical_certification_status: 'received')
      visit admin_application_path(@application)

      assert_no_selector '[data-testid="medical-certification-upload-form"]'
      assert_button 'Review Disability Certification'
    end

    test 'view link is shown when certification is approved' do
      @application.medical_certification.attach(io: StringIO.new('test content'), filename: 'cert.pdf', content_type: 'application/pdf')
      @application.update!(medical_certification_status: 'approved')
      visit admin_application_path(@application)

      assert_no_selector '[data-testid="medical-certification-upload-form"]'
      assert_link 'View Medical Certification Document'
    end

    # Certification actions

    test 'admin can approve a medical certification during upload' do
      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)

      wait_for_turbo

      assert_selector '[data-testid="medical-certification-upload-form"]', wait: 10

      within '[data-testid="medical-certification-upload-form"]' do
        choose 'Approve Certification and Upload'
        attach_file 'medical_certification', Rails.root.join('test/fixtures/files/medical_certification_valid.pdf')
        click_button 'Process Certification'
      end

      wait_for_turbo

      assert_success_message('Disability certification successfully uploaded and approved.')
      @application.reload
      assert @application.medical_certification.attached?, 'Medical certification file should be attached'
      assert_equal 'approved', @application.medical_certification_status
      assert_audit_event('medical_certification_status_changed', actor: @admin, auditable: @application)

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

      wait_for_turbo

      assert_selector '[data-testid="medical-certification-upload-form"]', wait: 10

      within '[data-testid="medical-certification-upload-form"]' do
        choose 'Reject Certification'
        assert_selector 'select[name="rejection_reason_code"]', visible: true, wait: 5
        select 'Missing Signature', from: 'rejection_reason_code'
        click_button 'Process Certification'
      end

      wait_for_turbo

      assert_success_message('Disability certification rejected and provider notified.')
      @application.reload
      assert_equal 'rejected', @application.medical_certification_status
      expected_reason = RejectionReason.find_by!(code: 'missing_signature', proof_type: 'medical_certification', locale: 'en').body
      assert_equal expected_reason, @application.medical_certification_rejection_reason
      assert_audit_event('medical_certification_status_changed', actor: @admin, auditable: @application)

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

        assert_field 'medical_certification_rejection_reason', disabled: false
        assert_selector 'label[for="medical_certification_rejection_reason"]', text: 'Custom Rejection Reason'
      end
    end

    # Required-input validation

    test 'approving without a file explains why and changes nothing' do
      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)

      wait_for_turbo

      assert_selector '[data-testid="medical-certification-upload-form"]', wait: 10

      within '[data-testid="medical-certification-upload-form"]' do
        choose 'Approve Certification and Upload'

        click_button 'Process Certification'
      end

      wait_for_turbo

      assert_error_message('Please select a file to upload')

      @application.reload
      assert_equal 'requested', @application.medical_certification_status

      clear_pending_network_connections if respond_to?(:clear_pending_network_connections)
    end

    test 'rejecting requires a reason before the form submits' do
      @application.update!(medical_certification_status: 'requested')
      visit admin_application_path(@application)
      wait_for_turbo

      within '[data-testid="medical-certification-upload-form"]' do
        choose 'Reject Certification'
        reason = find('select[name="rejection_reason_code"]')
        assert reason[:required], 'a rejection reason should be required'
        click_button 'Process Certification'
        assert_equal false, reason.evaluate_script('this.validity.valid')
      end

      assert_current_path admin_application_path(@application)
      assert_equal 'requested', @application.reload.medical_certification_status
    end

    test 'upload form is not shown when medical certification is already attached' do
      @application.medical_certification.attach(
        io: StringIO.new('test content'),
        filename: 'already_attached.pdf',
        content_type: 'application/pdf'
      )
      @application.update(medical_certification_status: 'received')

      visit admin_application_path(@application)

      assert_no_selector '[data-testid="medical-certification-upload-form"]'

      assert_text 'View Medical Certification Document'
    end
  end
end
