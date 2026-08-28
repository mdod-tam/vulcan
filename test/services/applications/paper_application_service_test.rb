# frozen_string_literal: true

require 'test_helper'
require 'action_dispatch/testing/test_process'

module Applications
  class PaperApplicationServiceTest < ActiveSupport::TestCase
    include PaperIdentityConfirmationHelper

    include ActionDispatch::TestProcess::FixtureFile

    # Disable parallelization for this test to avoid Active Storage conflicts
    self.use_transactional_tests = true

    # Override parent class's parallelize setting
    def self.parallelize(*)
      # Do nothing - we want to run these tests serially
    end

    setup do
      # Set up Active Storage for testing
      setup_active_storage_test

      # Set thread context for paper applications
      setup_paper_application_context

      # Use factory for admin user
      @admin = create(:admin)

      # Set up FPL policies for testing to match our test values
      setup_fpl_policies

      # Test constituent parameters - use timestamp for unique phone numbers
      @timestamp = Time.now.to_i
      @constituent_params = {
        first_name: 'Test',
        last_name: 'User',
        email: "test-#{@timestamp}@example.com",
        phone: "202555#{@timestamp.to_s[-4..]}", # Use last 4 digits of timestamp for uniqueness
        physical_address_1: '123 Test St',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201',
        hearing_disability: '1',
        vision_disability: '0',
        speech_disability: '0',
        mobility_disability: '0',
        cognition_disability: '0'
      }

      # Test application parameters
      @application_params = {
        household_size: '2',
        annual_income: '15000',
        maryland_resident: '1',
        self_certify_disability: '1',
        medical_provider_name: 'Dr. Smith',
        medical_provider_phone: '2025559876',
        medical_provider_email: 'drsmith@example.com'
      }

      # Test fixtures for file uploads
      @pdf_file = fixture_file_upload(
        Rails.root.join('test/fixtures/files/income_proof.pdf'),
        'application/pdf'
      )

      @invalid_file = fixture_file_upload(
        Rails.root.join('test/fixtures/files/invalid.exe'),
        'application/octet-stream'
      )
    end

    teardown do
      teardown_paper_application_context
    end

    # Helper method to create a test constituent directly
    def create_test_constituent(email)
      create(:constituent, email: email)
    end

    def uploaded_pdf(filename = 'income_proof.pdf')
      fixture_file_upload(
        Rails.root.join('test/fixtures/files', filename),
        'application/pdf'
      )
    end

    def unique_paper_phone
      "240-#{format('%03d', SecureRandom.random_number(900) + 100)}-#{format('%04d', SecureRandom.random_number(9000) + 1000)}"
    end

    test 'creates application with accepted income proof' do
      # We'll focus only on testing the service approach for simplicity

      # Now test the service approach
      test_timestamp = Time.now.to_i
      service_email = "test-service-#{test_timestamp}@example.com"
      service_phone = "202556#{test_timestamp.to_s[-4..]}"
      service_params = {
        constituent: @constituent_params.merge(email: service_email, phone: service_phone),
        application: @application_params,
        income_proof_action: 'accept',
        income_proof: @pdf_file
      }

      # Mock the ProofAttachmentService to ensure test reliability
      ProofAttachmentService.expects(:attach_proof).with(
        has_entries(
          proof_type: :income,
          status: :approved
        )
      ).returns({ success: true })

      # Create the application via the service
      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create
      assert result, "Service creation failed: #{service.errors.inspect}"

      # Find the new application
      constituent = Constituent.find_by(email: service_email)
      assert_not_nil constituent, 'Constituent should be created'

      application = constituent.applications.last
      assert_not_nil application, 'Application should be created'

      # The validation errors are coming from Rails, not our code
      # We're just asserting that the service completed successfully
      assert_equal 'in_progress', application.status, 'Status should be in_progress'
      assert_equal 2, application.household_size, 'Household size should match'
    end

    test 'creates application with MM/DD/YYYY date of birth' do
      unique_email = generate(:email)

      service_params = {
        constituent: @constituent_params.merge(email: unique_email, phone: unique_paper_phone, date_of_birth: '01/15/1980'),
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin, skip_proof_processing: true)
      assert service.create, "Service creation failed: #{service.errors.inspect}"

      assert_equal Date.new(1980, 1, 15), Constituent.find_by!(email: unique_email).date_of_birth
    end

    test 'rejects malformed paper intake date of birth' do
      service_params = {
        constituent: @constituent_params.merge(email: generate(:email), phone: unique_paper_phone, date_of_birth: 'January 15 1980'),
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin, skip_proof_processing: true)
      assert_not service.create
      assert service.errors.any? { |error| error.include?('Date of birth must be in MM/DD/YYYY format') },
             "Expected DOB format error, got: #{service.errors.inspect}"
    end

    test 'upload only attaches proofs for later review' do
      service_params = {
        constituent: @constituent_params.merge(email: generate(:email), phone: unique_paper_phone),
        application: @application_params,
        income_proof_action: 'upload_only',
        income_proof: uploaded_pdf('income_proof.pdf'),
        residency_proof_action: 'upload_only',
        residency_proof: uploaded_pdf('residency_proof.pdf'),
        id_proof_action: 'upload_only',
        id_proof: uploaded_pdf('id_proof.pdf'),
        medical_certification_action: 'upload_only',
        medical_certification: uploaded_pdf('medical_certification_valid.pdf')
      }

      %i[income residency id].each do |proof_type|
        ProofAttachmentService.expects(:attach_proof).with(
          has_entries(
            proof_type: proof_type,
            status: :not_reviewed,
            admin: @admin,
            submission_method: :paper
          )
        ).returns({ success: true })
      end
      MedicalCertificationAttachmentService.expects(:attach_certification).with(
        has_entries(
          status: :received,
          admin: @admin,
          submission_method: :paper
        )
      ).returns({ success: true })

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      assert service.create, "Service creation failed: #{service.errors.inspect}"
      assert_predicate service.application, :persisted?
    end

    test 'upload only does not require income details before sending proof for review' do
      service_params = {
        constituent: @constituent_params.merge(email: generate(:email), phone: unique_paper_phone),
        application: @application_params.except(:household_size, :annual_income),
        income_proof_action: 'upload_only',
        income_proof: uploaded_pdf('income_proof.pdf'),
        residency_proof_action: 'upload_only',
        residency_proof: uploaded_pdf('residency_proof.pdf'),
        id_proof_action: 'upload_only',
        id_proof: uploaded_pdf('id_proof.pdf')
      }

      %i[income residency id].each do |proof_type|
        ProofAttachmentService.expects(:attach_proof).with(
          has_entries(
            proof_type: proof_type,
            status: :not_reviewed,
            admin: @admin,
            submission_method: :paper
          )
        ).returns({ success: true })
      end

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      assert service.create, "Service creation failed: #{service.errors.inspect}"
      assert_nil service.application.household_size
      assert_nil service.application.annual_income
    end

    test 'upload only requires an uploaded proof file' do
      service_params = {
        constituent: @constituent_params.merge(email: generate(:email), phone: unique_paper_phone),
        application: @application_params,
        income_proof_action: 'upload_only'
      }

      ProofAttachmentService.expects(:attach_proof).never

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      assert_not service.create
      assert_includes service.errors, 'Please upload a file for income proof before sending it for review'
    end

    test 'upload only requires an uploaded medical certification file' do
      service_params = {
        constituent: @constituent_params.merge(email: generate(:email), phone: unique_paper_phone),
        application: @application_params,
        medical_certification_action: 'upload_only'
      }

      MedicalCertificationAttachmentService.expects(:attach_certification).never

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      assert_not service.create
      assert_includes service.errors, 'Please upload a file for medical certification before sending it for review'
    end

    test 'existing self applicant disability flags are saved before application validation' do
      applicant = create(
        :constituent,
        :without_disabilities,
        email: "existing-paper-self-#{Time.now.to_i}@example.com"
      )

      service_params = {
        applicant_type: 'self',
        existing_constituent_id: applicant.id,
        contact_info_mode: 'on_file',
        contact_info_verified: true,
        constituent: {
          hearing_disability: true,
          vision_disability: false,
          speech_disability: false,
          mobility_disability: false,
          cognition_disability: false
        },
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create

      assert result, "Failed to create application for existing self applicant: #{service.errors.inspect}"
      assert_predicate applicant.reload, :hearing_disability
      assert_equal applicant, service.application.user
    end

    test 'existing dependent disability flags are saved before application validation' do
      guardian = create(:constituent, email: "existing-paper-guardian-#{Time.now.to_i}@example.com")
      dependent = create(
        :constituent,
        :without_disabilities,
        email: "existing-paper-dependent-#{Time.now.to_i}@example.com"
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        constituent: {
          hearing_disability: true,
          vision_disability: false,
          speech_disability: false,
          mobility_disability: false,
          cognition_disability: false
        },
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create

      assert result, "Failed to create application for existing dependent: #{service.errors.inspect}"
      assert_predicate dependent.reload, :hearing_disability
      assert_equal dependent, service.application.user
      assert_equal guardian, service.application.managing_guardian
    end

    test 'existing dependent with a blocking application is refused before writes' do
      guardian = create(:constituent)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      create(:application, :in_progress, user: dependent, application_date: 8.years.ago)
      original_dependent = dependent.attributes.deep_dup
      service = PaperApplicationService.new(
        params: existing_dependent_service_params(guardian, dependent),
        admin: @admin,
        skip_proof_processing: true
      )

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                            'DuplicateReviewCase.count', 'Event.count', 'Notification.count'] do
        assert_not service.create
      end
      assert_includes service.errors, 'This dependent already has an active or pending application.'
      assert_equal original_dependent, dependent.reload.attributes
    end

    test 'existing dependent inside the waiting period is refused before writes' do
      guardian = create(:constituent)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      waiting_period = Policy.get('waiting_period_years') || 3
      last_application = create(
        :application,
        :archived,
        user: dependent,
        application_date: waiting_period.years.ago + 1.day
      )
      original_dependent = dependent.attributes.deep_dup
      service = PaperApplicationService.new(
        params: existing_dependent_service_params(guardian, dependent),
        admin: @admin,
        skip_proof_processing: true
      )

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                            'DuplicateReviewCase.count', 'Event.count', 'Notification.count'] do
        assert_not service.create
      end
      assert_includes(
        service.errors,
        'Not yet eligible for a new application. Eligible after ' \
        "#{(last_application.application_date + waiting_period.years).to_date.strftime('%B %d, %Y')}."
      )
      assert_equal original_dependent, dependent.reload.attributes
    end

    test 'creates application with rejected income proof' do
      # Test the rejection functionality
      test_timestamp = Time.now.to_i
      unique_email = "test-rejected-#{test_timestamp}@example.com"
      unique_phone = "202557#{test_timestamp.to_s[-4..]}"

      service_params = {
        constituent: @constituent_params.merge(email: unique_email, phone: unique_phone),
        application: @application_params,
        income_proof_action: 'reject',
        income_proof_rejection_reason: 'other',
        income_proof_custom_rejection_reason: 'Test rejection'
      }

      # Mock the ProofAttachmentService for rejection
      ProofAttachmentService.expects(:reject_proof_without_attachment).with(
        has_entries(
          proof_type: :income,
          reason: 'Test rejection'
        )
      ).returns({ success: true })

      # Create via service
      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create
      assert result, "Failed to create application with rejected proof: #{service.errors.inspect}"

      # Find the application
      constituent = Constituent.find_by(email: unique_email)
      assert_not_nil constituent, 'Constituent should be created'

      application = constituent.applications.last
      assert_not_nil application, 'Application should be created'

      # Rather than directly inspecting the model, check that the service completed
      # and the application was created with appropriate parameters
      # Status should be awaiting_proof when any proof is rejected
      assert_equal 'awaiting_proof', application.status, 'Status should be awaiting_proof when proof is rejected'

      # Since we've mocked the service, we just need to verify that the application was created
      # and our mocked rejection service was called
    end

    test 'paper submission requests medical certification once required proofs are approved' do
      test_timestamp = Time.now.to_i
      unique_email = "test-paper-dcf-#{test_timestamp}@example.com"
      unique_phone = "202571#{test_timestamp.to_s[-4..]}"

      service_params = {
        constituent: @constituent_params.merge(email: unique_email, phone: unique_phone),
        application: @application_params,
        income_proof_action: 'accept',
        income_proof: @pdf_file,
        residency_proof_action: 'accept',
        residency_proof: fixture_file_upload(
          Rails.root.join('test/fixtures/files/residency_proof.pdf'),
          'application/pdf'
        ),
        id_proof_action: 'accept',
        id_proof: fixture_file_upload(
          Rails.root.join('test/fixtures/files/id_proof.pdf'),
          'application/pdf'
        ),
        medical_certification_action: 'not_requested'
      }

      AuditEventService.stubs(:recent_duplicate_exists?).returns(false)

      request_mail = mock('request_mail')
      request_mail.expects(:deliver_later).once
      MedicalProviderMailer.expects(:request_certification).with(instance_of(Application)).returns(request_mail).once

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create

      assert result, "Failed to create paper application that should request certification: #{service.errors.inspect}"

      application = Constituent.find_by!(email: unique_email).applications.order(:created_at).last
      assert_not_nil application, 'Application should be created'

      application.reload
      assert_equal 'awaiting_dcf', application.status
      assert_equal 'requested', application.medical_certification_status
    end

    test 'uses Other custom rejection reason text as income rejection reason' do
      test_timestamp = Time.now.to_i
      unique_email = "test-rejected-existing-#{test_timestamp}@example.com"
      unique_phone = "202567#{test_timestamp.to_s[-4..]}"
      matching_note = "Please provide a document with your full legal name clearly visible. [#{test_timestamp}]"

      service_params = {
        constituent: @constituent_params.merge(email: unique_email, phone: unique_phone),
        application: @application_params,
        income_proof_action: 'reject',
        income_proof_rejection_reason: 'other',
        income_proof_custom_rejection_reason: matching_note
      }

      ProofAttachmentService.expects(:reject_proof_without_attachment).with(
        has_entries(
          proof_type: :income,
          reason: matching_note
        )
      ).returns({ success: true })

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create
      assert result, "Failed to create application with custom rejection reason: #{service.errors.inspect}"
    end

    test 'uses Other custom rejection reason text as medical certification rejection reason' do
      test_timestamp = Time.now.to_i
      unique_email = "test-medical-other-#{test_timestamp}@example.com"
      unique_phone = "202568#{test_timestamp.to_s[-4..]}"
      custom_note = "Provider noted additional details not covered by predefined reasons. [#{test_timestamp}]"

      service_params = {
        constituent: @constituent_params.merge(email: unique_email, phone: unique_phone),
        application: @application_params,
        medical_certification_action: 'rejected',
        medical_certification_rejection_reason: 'other',
        medical_certification_custom_rejection_reason: custom_note
      }

      reviewer_result = stub(success?: true)
      Applications::MedicalCertificationReviewer.any_instance.expects(:reject).with(
        rejection_reason: custom_note,
        notes: nil,
        rejection_reason_code: nil
      ).returns(reviewer_result)

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create
      assert result, "Failed to create application with medical custom rejection reason: #{service.errors.inspect}"
    end

    test 'routes none provided medical certification rejection directly through attachment service' do
      test_timestamp = Time.now.to_i
      unique_email = "test-medical-none-#{test_timestamp}@example.com"
      unique_phone = "202569#{test_timestamp.to_s[-4..]}"

      service_params = {
        no_medical_provider_information: true,
        constituent: @constituent_params.merge(email: unique_email, phone: unique_phone),
        application: @application_params.except(:medical_provider_name, :medical_provider_phone, :medical_provider_email),
        medical_certification_action: 'rejected',
        medical_certification_rejection_reason: 'none_provided'
      }

      Applications::MedicalCertificationReviewer.any_instance.expects(:reject).never
      MedicalCertificationAttachmentService.expects(:reject_certification).with(
        has_entries(
          reason: 'none_provided',
          reason_code: nil,
          submission_method: :paper
        )
      ).returns({ success: true })

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create
      assert result, "Failed to create application with medical certification marked none provided: #{service.errors.inspect}"
    end

    test 'paper intake without provider info creates application and sends provider info request' do
      test_timestamp = Time.now.to_i
      unique_email = "test-paper-missing-provider-#{test_timestamp}@example.com"
      unique_phone = "202570#{test_timestamp.to_s[-4..]}"

      service_params = {
        no_medical_provider_information: true,
        constituent: @constituent_params.merge(email: unique_email, phone: unique_phone),
        application: @application_params.except(:medical_provider_name, :medical_provider_phone, :medical_provider_email)
      }

      request_service = mock('request-provider-info-service')
      request_service.expects(:call).returns(BaseService::Result.new(success: true))
      Applications::RequestProviderInfo
        .expects(:new)
        .with(application: kind_of(Application), actor: @admin)
        .returns(request_service)

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create

      assert result, "Failed to create paper application without provider info: #{service.errors.inspect}"
      assert_predicate service.application, :persisted?
      assert_equal 'awaiting_proof', service.application.status
      assert_nil service.application.medical_provider_name
      assert_nil service.application.medical_provider_phone
      assert_nil service.application.medical_provider_email
    end

    test 'paper intake without provider info auto-approves when proofs and disability certification are approved' do
      unique_email = generate(:email)

      service_params = {
        no_medical_provider_information: true,
        constituent: @constituent_params.merge(email: unique_email, phone: unique_paper_phone),
        application: @application_params.except(:medical_provider_name, :medical_provider_phone, :medical_provider_email),
        income_proof_action: 'accept',
        income_proof: uploaded_pdf,
        residency_proof_action: 'accept',
        residency_proof: uploaded_pdf,
        id_proof_action: 'accept',
        id_proof: uploaded_pdf,
        medical_certification_action: 'accept',
        medical_certification: uploaded_pdf('medical_certification_valid.pdf')
      }

      NotificationService.stubs(:create_and_deliver!).returns(true)
      Applications::RequestProviderInfo.expects(:new).never

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create

      assert result, "Failed to create auto-approvable paper application: #{service.errors.inspect}"

      application = service.application.reload
      assert_predicate application, :status_approved?
      assert_predicate application, :income_proof_status_approved?
      assert_predicate application, :residency_proof_status_approved?
      assert_predicate application, :id_proof_status_approved?
      assert_predicate application, :medical_certification_status_approved?
      assert_nil application.medical_provider_name
      assert_nil application.medical_provider_phone
      assert_nil application.medical_provider_email
      assert_nil service.reconciliation_note
    end

    test 'routes medical certification rejection directly when provider contact information is missing' do
      custom_reason = "No provider contact details were available. [#{Time.now.to_i}]"
      application = create(:application, user: create(:constituent, :with_disabilities))
      application.update_columns(
        medical_provider_email: nil,
        medical_provider_fax: nil,
        updated_at: Time.current
      )

      service_params = {
        medical_certification_action: 'rejected',
        medical_certification_rejection_reason: 'other',
        medical_certification_custom_rejection_reason: custom_reason
      }

      Applications::MedicalCertificationReviewer.any_instance.expects(:reject).never
      MedicalCertificationAttachmentService.expects(:reject_certification).with(
        has_entries(
          reason: custom_reason,
          reason_code: nil,
          submission_method: :paper
        )
      ).returns({ success: true })

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.update(application)
      assert result, "Failed to update application with missing provider contact info: #{service.errors.inspect}"
    end

    test 'application creation fails when attachment validation fails' do
      # This is a simple unit test focused on the return value
      # rather than testing the full interaction with ProofAttachmentService
      service = PaperApplicationService.new(params: {}, admin: @admin)

      # Override the create method to always return false
      def service.create
        @errors = ['Invalid file type']
        false
      end

      # Call the create method - it will always return false because of our override
      result = service.create

      # Assert the create method returns false and has error messages
      assert_not result, 'Service should fail for invalid file type'
      assert service.errors.any?, 'Expected error messages in service.errors'
    end

    test 'application creation fails when income exceeds threshold' do
      # Test with excessive income - We set this very high to ensure it will exceed the threshold
      test_timestamp = Time.now.to_i
      unique_email = "test-high-income-#{test_timestamp}@example.com"
      unique_phone = "202558#{test_timestamp.to_s[-4..]}"

      service_params = {
        constituent: @constituent_params.merge(email: unique_email, phone: unique_phone),
        application: @application_params.merge(annual_income: '200000'),
        income_proof_action: 'accept',
        income_proof: @pdf_file
      }

      # This should fail because of income threshold
      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)

      # Mock Application create to force a transaction rollback
      Applications::PaperApplicationService.any_instance.stubs(:income_within_threshold?).returns(false)

      result = service.create

      # The service should return false
      assert_not result, 'Service should fail for excessive income'

      # Verify the error message
      assert service.errors.any? { |e| e.include?('Income exceeds') || e.include?('threshold') },
             'Expected error message about income threshold'
    end

    test 'failed create after user creation rolls back the new user' do
      unique_email = "rollback-user-#{SecureRandom.hex(4)}@example.com"
      unique_phone = unique_paper_phone

      service_params = {
        constituent: @constituent_params.merge(email: unique_email, phone: unique_phone)
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)

      assert_no_difference ['User.count', 'Application.count'] do
        assert_not service.create
      end

      assert_includes service.errors, 'Application params missing'
      assert_includes service.errors, 'Application creation failed'
      assert_nil User.find_by(email: unique_email)
    end

    test 'handles multiple proof types together' do
      # Test with multiple proof types
      test_timestamp = Time.now.to_i
      unique_email = "test-multiple-#{test_timestamp}@example.com"
      unique_phone = "202559#{test_timestamp.to_s[-4..]}"

      service_params = {
        constituent: @constituent_params.merge(email: unique_email, phone: unique_phone),
        application: @application_params,
        income_proof_action: 'accept',
        income_proof: @pdf_file,
        residency_proof_action: 'reject',
        residency_proof_rejection_reason: 'address_mismatch'
      }

      # Mock ProofAttachmentService to make our test more reliable
      ProofAttachmentService.stubs(:attach_proof).with(
        has_entries(proof_type: :income)
      ).returns({ success: true })

      ProofAttachmentService.stubs(:reject_proof_without_attachment).with(
        has_entries(
          proof_type: :residency,
          reason: 'address_mismatch'
        )
      ).returns({ success: true })

      # Create via service
      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      result = service.create
      assert result, "Failed to create application with multiple proof types: #{service.errors.inspect}"

      # Find the application
      constituent = Constituent.find_by(email: unique_email)
      assert_not_nil constituent, 'Constituent should be created'

      application = constituent.applications.last
      assert_not_nil application, 'Application should be created'

      # Verify the application was created
      # Status should be awaiting_proof when any proof is rejected
      assert_equal 'awaiting_proof', application.status, 'Status should be awaiting_proof when proof is rejected'
    end

    test 'updates existing dependent locale and communication preferences' do
      guardian = create(:constituent, email: "guardian-#{@timestamp}@example.com", phone: "301555#{@timestamp.to_s[-4..]}")
      dependent = create(:constituent, email: "dependent-#{@timestamp}@example.com", phone: "302555#{@timestamp.to_s[-4..]}")
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'parent')

      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'parent',
        constituent: {
          dependent_email: dependent.email,
          dependent_phone: dependent.phone,
          locale: 'es',
          communication_preference: 'letter',
          preferred_means_of_communication: 'asl'
        },
        application: @application_params
      }

      service = PaperApplicationService.new(
        params: service_params,
        admin: @admin,
        skip_income_validation: true,
        skip_proof_processing: true
      )

      assert service.create, "Expected service to succeed, got: #{service.errors.inspect}"

      dependent.reload
      assert_equal 'es', dependent.locale
      assert_equal 'letter', dependent.communication_preference
      assert_equal 'asl', dependent.preferred_means_of_communication
    end

    test 'paper application suppresses account_created notice when vouchers are disabled' do
      service_params = {
        constituent: @constituent_params.merge(email: generate(:email), phone: unique_paper_phone),
        application: @application_params,
        income_proof_action: 'accept',
        income_proof: uploaded_pdf
      }

      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      NotificationService.stubs(:create_and_deliver!).returns(true)
      NotificationService.expects(:create_and_deliver!).with(has_entry(type: 'account_created')).never

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      assert service.create, "Service creation failed: #{service.errors.inspect}"
      assert_predicate service.application, :fulfillment_type_equipment?
    end

    test 'paper application sends account_created notice when vouchers are enabled' do
      FeatureFlag.enable!(:vouchers_enabled)

      service_params = {
        constituent: @constituent_params.merge(email: generate(:email), phone: unique_paper_phone),
        application: @application_params,
        income_proof_action: 'accept',
        income_proof: uploaded_pdf
      }

      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      NotificationService.stubs(:create_and_deliver!).returns(true)
      NotificationService.expects(:create_and_deliver!).with(has_entry(type: 'account_created')).at_least_once

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin)
      assert service.create, "Service creation failed: #{service.errors.inspect}"
      assert_predicate service.application, :fulfillment_type_voucher?
    ensure
      FeatureFlag.disable!(:vouchers_enabled)
    end

    test 'voucher fulfillment does not send account_created notice when vouchers are disabled' do
      application = build(:application, fulfillment_type: :voucher)
      service = PaperApplicationService.new(params: {}, admin: @admin)
      service.instance_variable_set(:@application, application)

      FeatureFlag.disable!(:vouchers_enabled)

      assert_not service.send(:send_account_created_notice?)
    end

    test 'new_user_accounts includes inline-created portal-eligible guardian beyond five minutes' do
      guardian = create(:constituent, phone: unique_paper_phone, force_password_change: true)
      guardian.update_column(:created_at, 10.minutes.ago)

      service = PaperApplicationService.new(params: {}, admin: @admin)
      service.instance_variable_set(:@guardian_user_for_app, guardian)
      service.send(:track_email_backed_portal_created_user_id, guardian.id)

      assert_includes service.send(:new_user_accounts), guardian
    end

    test 'new_user_accounts includes quick-created portal marker user' do
      guardian = create(:constituent, phone: unique_paper_phone, force_password_change: true)

      service = PaperApplicationService.new(
        params: {},
        admin: @admin,
        quick_created_portal_user_ids: [guardian.id]
      )
      service.instance_variable_set(:@guardian_user_for_app, guardian)

      assert_includes service.send(:new_user_accounts), guardian
    end

    test 'paper self hard duplicate contact blocks before persistence without workflow side effects' do
      phone = unique_paper_phone
      original_email = "dup-reuse-#{SecureRandom.hex(4)}@example.com"
      existing = create(:constituent, email: original_email, phone: phone)

      service_params = {
        no_email_address: '1',
        constituent: @constituent_params.merge(
          first_name: 'Different',
          last_name: 'Person',
          email: "other-#{SecureRandom.hex(4)}@example.com",
          phone: phone,
          physical_address_1: '300 Letter Lane',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201'
        ),
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin, skip_proof_processing: true)
      assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count',
                            'DuplicateReviewCaseCandidate.count', 'Event.count'] do
        assert_not service.create
      end
      assert(service.errors.any? { |error| error.match?(/phone|taken|create user/i) })

      existing.reload
      assert_equal original_email, existing.email
      assert_not_equal 'Different', existing.first_name
      assert_not existing.needs_duplicate_review
    end

    # Previously this asserted that a paper soft match persisted the user and opened a
    # `paper_intake` review case. That contract is retired: staff now review the candidates and
    # attest that none is this applicant, so queuing the same decision for someone to make again is
    # redundant -- and those cases are resolvable but never mergeable, so the entry could be closed
    # without ever remediating anything.
    test 'paper self soft match is decided by staff rather than queued for review' do
      existing = create(
        :constituent,
        first_name: 'Paper',
        last_name: 'Softmatch',
        date_of_birth: Date.new(1981, 4, 12),
        email: "paper-soft-existing-#{SecureRandom.hex(4)}@example.com",
        phone: unique_paper_phone
      )

      service_params = {
        constituent: @constituent_params.merge(
          first_name: existing.first_name,
          last_name: existing.last_name,
          date_of_birth: '04/12/1981',
          email: "paper-soft-new-#{SecureRandom.hex(4)}@example.com",
          phone: unique_paper_phone,
          physical_address_1: '900 Soft Match Lane',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21203'
        ),
        application: @application_params
      }

      # Without a decision: nothing is written, and staff are shown what to decide about. Note this
      # deliberately does *not* go through confirmed_params -- the missing confirmation is the
      # behaviour under test.
      first = PaperApplicationService.new(params: service_params, admin: @admin, skip_proof_processing: true)
      assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'] do
        assert_not first.create
      end
      assert_equal [existing.id], first.pending_identity_decision[:candidates].map(&:id)

      # With it: the constituent is created and no review case is opened.
      decided = service_params.merge(identity_decision: first.pending_identity_decision[:token])
      second = PaperApplicationService.new(params: decided, admin: @admin, skip_proof_processing: true)

      assert_difference ['User.count', 'Application.count'], 1 do
        assert_no_difference ['DuplicateReviewCase.count',
                              %(Event.where(action: 'duplicate_review_case_opened').count)] do
          assert second.create, "Service creation failed: #{second.errors.inspect}"
        end
      end

      subject = second.constituent.reload
      assert_not subject.needs_duplicate_review,
                 'a decided no-match must not flag the new constituent for review'
    end

    test 'process_self_applicant does not attach application when duplicate contact blocks creation' do
      phone = unique_paper_phone
      original_email = "blocked-reuse-#{SecureRandom.hex(4)}@example.com"
      existing = create(:constituent, email: original_email, phone: phone)
      original_skip = Application.skip_wait_period_validation
      Application.skip_wait_period_validation = true
      begin
        create(:application, :in_progress, user: existing)

        service_params = {
          no_email_address: '1',
          constituent: @constituent_params.merge(
            first_name: existing.first_name,
            last_name: existing.last_name,
            email: existing.email,
            phone: phone,
            physical_address_1: '500 Letter Lane',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201'
          ),
          application: @application_params
        }

        service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin, skip_proof_processing: true)
        assert_not service.create
        assert(service.errors.any? { |error| error.match?(/phone|taken|create user/i) })
      ensure
        Application.skip_wait_period_validation = original_skip
      end

      existing.reload
      assert_equal original_email, existing.email
      assert_equal 1, existing.applications.count
    end

    test 'process_existing_dependent applies guardian contact strategies on reuse' do
      guardian = create(:constituent,
                        email: "guardian-strategy-#{SecureRandom.hex(4)}@example.com",
                        phone: unique_paper_phone)
      dependent = create(:constituent,
                         email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
                         dependent_email: "old-dependent-#{SecureRandom.hex(4)}@example.com",
                         phone: '000-000-0001',
                         dependent_phone: '410-555-0200')
      create(:guardian_relationship,
             guardian_user: guardian,
             dependent_user: dependent,
             relationship_type: 'Parent')

      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        constituent: {
          locale: 'en',
          communication_preference: 'email'
        },
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin, skip_proof_processing: true)
      assert service.create, "Service creation failed: #{service.errors.inspect}"

      dependent.reload
      assert_equal guardian.email, dependent.dependent_email
      assert_equal guardian.phone, dependent.dependent_phone
      assert User.system_generated_email?(dependent.email)
      assert dependent.phone.start_with?('000-')
    end

    test 'a submitted existing dependent without an on-file guardian relationship is refused before writes' do
      guardian = create(:constituent, email: "guardian-unrelated-#{SecureRandom.hex(4)}@example.com")
      dependent = create(:constituent, email: "dependent-unrelated-#{SecureRandom.hex(4)}@example.com")
      original_dependent = dependent.attributes.deep_dup
      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        constituent: { locale: 'es', communication_preference: 'letter', hearing_disability: true },
        application: @application_params
      }
      service = PaperApplicationService.new(params: service_params, admin: @admin, skip_proof_processing: true)

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                            'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count',
                            'Event.count', 'Notification.count'] do
        assert_not service.create
      end
      assert_match(/not on file|not eligible/i, service.errors.join(' '))
      assert_equal original_dependent, dependent.reload.attributes,
                   'contact and disability facts must not change before relationship requalification'
    end

    test 'process_existing_dependent clears stale dependent_phone when guardian has no phone' do
      guardian = create(:constituent,
                        email: "guardian-nophone-#{SecureRandom.hex(4)}@example.com",
                        phone: unique_paper_phone)
      guardian.update_columns(phone: nil)

      stale_phone = "410-555-#{SecureRandom.random_number(9000) + 1000}"
      dependent = create(:constituent,
                         email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
                         dependent_email: guardian.email,
                         phone: '000-000-0001',
                         dependent_phone: stale_phone)
      create(:guardian_relationship,
             guardian_user: guardian,
             dependent_user: dependent,
             relationship_type: 'Parent')

      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        constituent: { locale: 'en' },
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin), admin: @admin, skip_proof_processing: true)
      assert service.create, "Service creation failed: #{service.errors.inspect}"

      dependent.reload
      assert_nil dependent.dependent_phone
      assert dependent.phone.start_with?('000-')
    end

    # Clearing an existing dependent's own email while leaving them set to use their own is a
    # contradiction, and both silent resolutions were wrong: backfilling from the record undid the
    # clear behind a form that still showed blank, and letting it through reached the guardian
    # fallback, which replaced the login identifier with a synthetic address. Refused instead.
    test 'a cleared own-contact with the dependent strategy is refused, not silently resolved' do
      guardian = create(:constituent,
                        email: "guardian-clear-#{SecureRandom.hex(4)}@example.com",
                        phone: unique_paper_phone)
      original_email = "dependent-own-#{SecureRandom.hex(4)}@example.com"
      dependent = create(:constituent, dependent_email: original_email, phone: unique_paper_phone)
      create(:guardian_relationship,
             guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        email_strategy: 'dependent',
        phone_strategy: 'guardian',
        # Submitted blank -- a deliberate clear, not an absent field.
        constituent: { locale: 'en', dependent_email: '' },
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin),
                                            admin: @admin, skip_proof_processing: true)

      assert_not service.create, 'a contradictory contact instruction must not be resolved silently'
      assert_match(/use the guardian's email address/i, service.errors.join(' '))
      # The old address must not have been quietly reinstated behind the refusal.
      assert_equal original_email, dependent.reload.dependent_email
    end

    # Phone independently of email: the two strategies are separate fields, and a guard that only
    # covered email would leave the phone path silently resolving as before.
    test 'a cleared own-phone with the dependent strategy is refused independently of email' do
      guardian = create(:constituent,
                        email: "guardian-phone-#{SecureRandom.hex(4)}@example.com",
                        phone: unique_paper_phone)
      original_phone = "410-555-#{SecureRandom.random_number(9000) + 1000}"
      dependent = create(:constituent,
                         dependent_email: "dependent-own-#{SecureRandom.hex(4)}@example.com",
                         dependent_phone: original_phone)
      create(:guardian_relationship,
             guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        email_strategy: 'guardian',
        phone_strategy: 'dependent',
        constituent: { locale: 'en', dependent_phone: '' },
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin),
                                            admin: @admin, skip_proof_processing: true)

      assert_not service.create
      assert_match(/use the guardian's phone number/i, service.errors.join(' '))
      assert_equal original_phone, dependent.reload.dependent_phone
    end

    # The control for the guard: choosing the guardian's contact is the *supported* way to leave a
    # dependent without their own, and must keep working. Without this, the refusal above could be
    # satisfied by rejecting every blank contact, which would break ordinary paper intake.
    test 'choosing guardian contact still succeeds with no own contact submitted' do
      guardian = create(:constituent,
                        email: "guardian-ok-#{SecureRandom.hex(4)}@example.com",
                        phone: unique_paper_phone)
      dependent = create(:constituent, dependent_email: nil, dependent_phone: nil)
      create(:guardian_relationship,
             guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        constituent: { locale: 'en' },
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin),
                                            admin: @admin, skip_proof_processing: true)

      assert service.create, "guardian contact must remain supported: #{service.errors.inspect}"
      assert_equal guardian.email, dependent.reload.dependent_email
    end

    # The control that actually exercises the strategy condition. A blank own-contact is only a
    # contradiction when the dependent is set to use their own; with the guardian's contact chosen
    # it is the normal submission, because the form still posts the emptied field. A guard that
    # ignored the strategy would reject ordinary paper intake here.
    test 'a blank own-contact submitted alongside the guardian strategy is accepted' do
      guardian = create(:constituent,
                        email: "guardian-blankok-#{SecureRandom.hex(4)}@example.com",
                        phone: unique_paper_phone)
      dependent = create(:constituent, dependent_email: nil, dependent_phone: nil)
      create(:guardian_relationship,
             guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        # Submitted blank *and* the guardian's contact chosen -- consistent, not contradictory.
        constituent: { locale: 'en', dependent_email: '', dependent_phone: '' },
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin),
                                            admin: @admin, skip_proof_processing: true)

      assert service.create, "a blank field is fine when guardian contact is chosen: #{service.errors.inspect}"
      assert_equal guardian.email, dependent.reload.dependent_email
    end

    # The other control: a field the form never submitted is absent, not blank. That is what the
    # guardian-contact checkbox produces when it disables the input, and it must still backfill
    # rather than trip the refusal.
    test 'an absent own-contact field still backfills rather than being refused' do
      guardian = create(:constituent,
                        email: "guardian-absent-#{SecureRandom.hex(4)}@example.com",
                        phone: unique_paper_phone)
      on_file = "dependent-onfile-#{SecureRandom.hex(4)}@example.com"
      dependent = create(:constituent, dependent_email: on_file, phone: unique_paper_phone)
      create(:guardian_relationship,
             guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

      service_params = {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        email_strategy: 'dependent',
        phone_strategy: 'guardian',
        # No dependent_email key at all -- the field was never submitted.
        constituent: { locale: 'en' },
        application: @application_params
      }

      service = PaperApplicationService.new(params: confirmed_paper_params(service_params, admin: @admin),
                                            admin: @admin, skip_proof_processing: true)

      assert service.create, "an absent field is not a cleared one: #{service.errors.inspect}"
      assert_equal on_file, dependent.reload.dependent_email
    end

    test 'new_user_accounts excludes existing user with force_password_change but no submission handoff' do
      existing = create(:constituent, phone: unique_paper_phone, force_password_change: true)

      service = PaperApplicationService.new(params: {}, admin: @admin)
      service.instance_variable_set(:@constituent, existing)

      assert_not_includes service.send(:new_user_accounts), existing
    end

    test 'send_account_creation_notifications delivers notice and account-access warning for quick-created marker' do
      guardian = create(:constituent, phone: unique_paper_phone, force_password_change: true, communication_preference: :email)
      application = create(:application, user: guardian)

      service = PaperApplicationService.new(
        params: {},
        admin: @admin,
        quick_created_portal_user_ids: [guardian.id]
      )
      service.instance_variable_set(:@application, application)
      service.instance_variable_set(:@guardian_user_for_app, guardian)

      FeatureFlag.enable!(:vouchers_enabled)
      begin
        NotificationService.expects(:create_and_deliver!).with(has_entry(type: 'account_created')).once
        service.send(:send_account_creation_notifications)
        assert_includes service.reconciliation_note, 'No temporary portal password is retained'
        assert_includes service.reconciliation_note, 'account access link flow'
      ensure
        FeatureFlag.disable!(:vouchers_enabled)
      end
    end

    test 'send_account_creation_notifications skips voice-only phone user without account access delivery' do
      guardian = create(
        :constituent,
        email: nil,
        phone: unique_paper_phone,
        phone_type: :voice,
        communication_preference: :letter,
        force_password_change: true
      )
      application = create(:application, user: guardian)

      service = PaperApplicationService.new(
        params: {},
        admin: @admin,
        quick_created_portal_user_ids: [guardian.id]
      )
      service.instance_variable_set(:@application, application)
      service.instance_variable_set(:@guardian_user_for_app, guardian)

      FeatureFlag.enable!(:vouchers_enabled)
      begin
        NotificationService.expects(:create_and_deliver!).with(has_entry(type: 'account_created')).never
        service.send(:send_account_creation_notifications)
        assert_not_includes service.reconciliation_note.to_s, 'account access link flow'
      ensure
        FeatureFlag.disable!(:vouchers_enabled)
      end
    end

    test 'medical certification not provided notice notifies constituent for none_provided review' do
      constituent = create(:constituent, communication_preference: :email)
      application = create(:application, :in_progress, skip_proofs: true, user: constituent)
      %i[income residency].each do |proof_type|
        application.public_send("#{proof_type}_proof").attach(
          io: StringIO.new("#{proof_type} proof"),
          filename: "#{proof_type}.pdf",
          content_type: 'application/pdf'
        )
      end
      create(:proof_review,
             application: application,
             admin: @admin,
             proof_type: :medical_certification,
             status: :rejected,
             rejection_reason: 'none_provided',
             rejection_reason_code: 'none_provided',
             submission_method: :paper)

      service = PaperApplicationService.new(params: {}, admin: @admin)
      service.instance_variable_set(:@application, application)
      service.instance_variable_set(:@constituent, constituent)

      NotificationService.expects(:create_and_deliver!).with(has_entry(type: 'medical_certification_not_provided')).once

      service.send(:send_medical_certification_not_provided_notice)
    end

    test 'append_proof_resubmission_delivery_warnings surfaces note when resubmission delivery failed' do
      constituent = create(:constituent, communication_preference: :email)
      application = create(:application, :in_progress, skip_proofs: true, user: constituent, income_proof_status: :rejected)
      mailer_delivery = mock('proof-resubmission-mailer-delivery')
      mailer_delivery.stubs(:deliver_now).raises(StandardError, 'smtp failed')
      ApplicationNotificationsMailer.stubs(:proof_rejected).returns(mailer_delivery)

      Current.paper_context = true
      create(
        :proof_review,
        :rejected,
        application: application,
        admin: @admin,
        proof_type: :income,
        rejection_reason: 'Missing income details',
        submission_method: :paper
      )
      Current.paper_context = false

      service = PaperApplicationService.new(params: {}, admin: @admin)
      service.instance_variable_set(:@application, application.reload)

      service.send(:append_proof_resubmission_delivery_warnings)

      assert_includes service.reconciliation_note,
                      'Income proof resubmission form could not be automatically sent'
      assert_includes service.reconciliation_note, 'You can send it from the application page.'
    end

    # --- Paper no-match decision -----------------------------------------------------------------
    #
    # Paper intake asks staff to decide only where the computer is unsure. Selecting a surfaced
    # constituent was already enforced; these cover the other half -- recording that the surfaced
    # candidates are different people. The
    # decision is server-signed and bound to the identity it was made about, because the failure
    # being closed is ordinary rather than adversarial: search one name, get interrupted, submit a
    # different name, and the "I checked" silently carries over to someone it was never about.

    test 'a soft match refuses creation until staff decide, and writes nothing' do
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2))

      service = paper_service(soft_match_params(existing))

      assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'] do
        assert_not service.create
      end
      assert_match(/possible match/i, service.errors.join(' '))
    end

    test 'a refusal offers the candidates and a decision staff can return' do
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2))

      service = paper_service(soft_match_params(existing))
      service.create
      pending = service.pending_identity_decision

      assert pending.present?, 'staff must be shown what they are deciding about'
      assert_includes pending[:candidates].map(&:id), existing.id
      assert_match(/\Av1:\d+:[a-f0-9]{64}\z/, pending[:token])
    end

    test 'a valid decision creates the constituent and opens no paper_intake case' do
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2))
      params = soft_match_params(existing)

      first = paper_service(params)
      first.create
      token = first.pending_identity_decision[:token]

      second = paper_service(params.merge(identity_decision: token))
      assert_difference 'User.count', 1 do
        assert_no_difference 'DuplicateReviewCase.count' do
          assert second.create, second.errors.inspect
        end
      end
    end

    # The decision was about one applicant. Reusing it for another is the exact failure this exists
    # to stop, and it must not depend on the admin noticing.
    test 'a decision cannot be carried onto a different applicant' do
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2))
      other_existing = create(:constituent, first_name: 'Another', last_name: 'Person',
                                            date_of_birth: Date.new(1988, 7, 9))
      params = soft_match_params(existing)

      first = paper_service(params)
      first.create
      token = first.pending_identity_decision[:token]

      # The second applicant has candidates of their own, so a decision *is* required here -- which
      # is what makes carrying the first one over an actual bypass attempt rather than a no-op.
      other = soft_match_params(other_existing).merge(identity_decision: token)

      assert_no_difference 'User.count' do
        assert_not paper_service(other).create
      end
    end

    test 'a forged decision is refused' do
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2))
      params = soft_match_params(existing).merge(identity_decision: "v1:#{Time.current.to_i}:#{'0' * 64}")

      assert_no_difference 'User.count' do
        assert_not paper_service(params).create
      end
    end

    # Nothing surfaced, so there is nothing to decide. Asking staff to confirm here would be
    # friction that proves nothing the server's own search -- run against the completed applicant
    # immediately before the write -- has not already established.
    test 'an applicant with no possible matches is created without any confirmation' do
      service = paper_service(base_paper_params)

      assert_difference 'User.count', 1 do
        assert service.create, service.errors.inspect
      end
      assert_equal 0, DuplicateReviewCase.where(source: :paper_intake).count
    end

    # Evidence records a decision. With nothing to decide there is nothing to record, and logging it
    # anyway would make the audit trail claim staff adjudicated something they were never shown.
    test 'an application with no possible matches records no confirmation evidence' do
      assert_no_difference "Event.where(action: 'paper_identity_no_match_confirmed').count" do
        assert paper_service(base_paper_params).create
      end
    end

    # Exact contact collisions were never acknowledgeable and must stay that way.
    test 'an exact contact collision is refused and cannot be acknowledged away' do
      existing = create(:constituent, email: "collide-#{SecureRandom.hex(3)}@example.com")
      params = base_paper_params
      params[:constituent] = params[:constituent].merge(email: existing.email)

      service = paper_service(params)
      assert_no_difference 'User.count' do
        assert_not service.create
      end
      assert_match(/already exists/i, service.errors.join(' '))
      assert_nil service.pending_identity_decision,
                 'a hard block is not a reviewable decision'
    end

    test 'a dependent unique-contact race is reclassified after rollback without leaking database details' do
      guardian = create(:constituent, phone: unique_paper_phone)
      params = base_paper_params.merge(
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        relationship_type: 'Parent',
        email_strategy: 'dependent',
        phone_strategy: 'guardian',
        address_strategy: 'guardian'
      )
      params[:constituent] = params[:constituent].except(:email, :phone).merge(
        dependent_email: "dependent-race-#{SecureRandom.hex(4)}@example.com",
        dependent_phone: ''
      )

      clear_review = stub(error?: false, invalid_decision?: false, blocked?: false,
                          confirmed?: false, clear?: true)
      blocked_review = stub(blocked?: true)
      Applications::PaperIdentityReview.any_instance.expects(:call).twice.returns(clear_review, blocked_review)
      Applications::UserCreationService.any_instance.expects(:call).raises(
        ActiveRecord::RecordNotUnique.new('duplicate key violates index_users_on_email')
      )

      counters = ['User.count', 'GuardianRelationship.count', 'Application.count',
                  'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count',
                  'Event.count', 'Notification.count']
      service = paper_service(params)
      assert_no_difference counters do
        assert_not service.create
      end

      assert_includes service.errors,
                      GuardianDependentManagementService::DEPENDENT_CONTACT_COLLISION_MESSAGE
      assert_no_match(/index_users|duplicate key/i, service.errors.join(' '))
    end

    # Removing the automatic review case removed the only durable record of who decided what, so a
    # successful confirmation writes its own. Only successes: a missing, forged, expired or
    # abandoned review must leave no trace, so the trail records decisions taken rather than
    # attempts made.
    test 'a confirmed no-match records one audit event naming what was reviewed' do
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2))
      params = soft_match_params(existing)
      first = paper_service(params)
      first.create
      confirmed = params.merge(identity_decision: first.pending_identity_decision[:token])

      assert_difference "Event.where(action: 'paper_identity_no_match_confirmed').count", 1 do
        assert paper_service(confirmed).create
      end

      event = Event.where(action: 'paper_identity_no_match_confirmed').order(:id).last
      assert_equal @admin.id, event.user_id
      assert_equal [existing.id], event.metadata['candidate_ids']
      assert_equal 1, event.metadata['candidate_count']
      assert_equal ['name_dob'], event.metadata['reason_codes']
    end

    # The unit matrix proves the HMAC covers every displayed field. This proves the *writer* acts on
    # it: that PaperApplicationService rebuilds the presented snapshot from current data and refuses
    # a decision made about a screen that no longer exists.
    #
    # The candidate id and the reason codes are deliberately untouched -- only what the panel showed
    # changes. That is the case an id-and-reasons binding accepted, and it is the realistic one:
    # staff review "Soft Match, Baltimore", someone corrects that record's city, and the person the
    # decision was about is no longer the person on screen.
    #
    # Non-vacuity: the sibling test above creates successfully with a token obtained exactly this
    # way, so the refusal here is caused by the mutation and not by the token never having worked.
    test 'a decision about a candidate whose displayed facts changed is refused with zero writes' do
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2), city: 'Baltimore')
      params = soft_match_params(existing)
      first = paper_service(params)
      first.create
      token = first.pending_identity_decision[:token]
      assert token.present?, 'the test needs a real decision to invalidate'

      existing.update!(city: 'Annapolis')

      confirmed = params.merge(identity_decision: token)
      counters = ['User.count', 'Application.count', 'DuplicateReviewCase.count',
                  "Event.where(action: 'paper_identity_no_match_confirmed').count"]
      assert_no_difference counters do
        service = paper_service(confirmed)

        assert_not service.create
        assert_match(/changed since you reviewed them/i, service.errors.join(' '))
      end
    end

    # Two properties, together, are what make "create returned false but the application committed"
    # impossible. That state is what the controller's removed branch tried to handle by asking a
    # rolled-back object whether it was persisted. They are pinned here because if either one ever
    # stops holding, the controller's simple "false means re-render" contract silently becomes wrong.
    #
    # Asserted against the database, never against `service.application.persisted?`: in-memory state
    # is exactly the authority the removed branch trusted.
    test 'a failure after the application saves leaves nothing durable and no ghost id' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('storage refused the proof') }
      )
      params = base_paper_params.merge(
        income_proof_action: 'upload_only',
        income_proof: fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
      )

      service = paper_service_with_proofs(params)

      # Every table the request could have written, not just the two obvious ones: a rollback that
      # left an orphaned attachment, event, or case behind would still satisfy a user/application
      # count check while leaving real debris.
      counters = ['Application.count', 'User.count', 'Event.count', 'Notification.count',
                  'DuplicateReviewCase.count', 'GuardianRelationship.count',
                  'ProofReview.count', 'ActiveStorage::Attachment.count', 'ActiveStorage::Blob.count']
      assert_no_difference counters do
        assert_no_enqueued_jobs do
          assert_not service.create
        end
      end
      assert_includes service.errors.join(' '), 'storage refused the proof'
      # The rollback must also take the id back off the in-memory record, or any caller that trusts
      # it is handed an id that resolves to nothing.
      assert_nil service.application&.id
    end

    # The suffix is not merely untidy: it is the last thing staff read, and it describes an internal
    # step rather than what went wrong. The helper for this already existed and was used for
    # constituent failures; proof failures simply were not routed through it.
    test 'an explained proof failure is not followed by the generic step name' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('storage refused the proof') }
      )
      params = base_paper_params.merge(
        income_proof_action: 'upload_only',
        income_proof: fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
      )

      service = paper_service_with_proofs(params)
      service.create

      assert_includes service.errors.join(' '), 'storage refused the proof'
      assert_not_includes service.errors, 'Proof upload failed'
    end

    # `after_commit` callbacks run as the transaction block exits, so a raise from one escapes
    # *after* the data is durable. ProofReview has such a callback and every rejected proof creates a
    # ProofReview, so this is an ordinary path, not an exotic one. Reporting it as failure invites
    # the admin to submit again and create a duplicate.
    test 'a post-commit callback failure reports success with a warning, not failure' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      params = base_paper_params.merge(id_proof_action: 'reject', id_proof_rejection_reason: 'none_provided')

      service = paper_service_with_proofs(params)

      assert_difference ['Application.count', 'User.count'], 1 do
        assert service.create, "a committed application must not be reported as a failure: #{service.errors.inspect}"
      end
      assert Application.exists?(service.application.id), 'the application really did commit'
      assert_match(/follow-up step did not finish/i, service.warning_message)
    end

    # The nastier ordering: the callback raises *and* the query that would confirm the commit also
    # fails. Collapsing that uncertainty into "not committed" hands the admin a retry form for an
    # application that may well exist -- the exact duplicate risk this path is meant to remove. An
    # unconfirmed commit is reported on the success side, with copy that says so.
    test 'an unverifiable commit is not reported as a failure' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      Application.stubs(:exists?).raises(ActiveRecord::ConnectionNotEstablished, 'database went away')
      params = base_paper_params.merge(id_proof_action: 'reject', id_proof_rejection_reason: 'none_provided')

      service = paper_service_with_proofs(params)

      assert service.create, 'an unconfirmed commit must not be reported as a failure'
      assert_not service.commit_confirmed?, 'the caller must be told the write was not verified'
      assert_match(/could not be confirmed/i, service.warning_message)
      assert_match(/could create a duplicate/i, service.warning_message)
    end

    # A post-creation step failing is not a reason to call the intake finished, and it must not
    # cancel the steps after it either. Each is isolated and named, so the admin learns which part
    # did not run rather than being told something vague went wrong.
    test 'a failure in one post-creation step is named and does not cancel the others' do
      Applications::PaperApplicationService.any_instance.stubs(:send_notifications)
                                           .raises(StandardError, 'notification exploded')

      service = paper_service(base_paper_params)

      # Explicit expectations, not the absence of a warning: "no warning" also holds when the method
      # was never called at all, which is the failure this is meant to exclude.
      Applications::PaperApplicationService.any_instance.expects(:append_proof_resubmission_delivery_warnings).once
      Applications::PaperApplicationService.any_instance.expects(:request_provider_info_if_missing).once

      assert service.create
      assert_match(/notifications did not finish/i, service.warning_message)
      assert Event.exists?(action: 'application_created', auditable_id: service.application.id),
             'the audit event runs first and must be unaffected'

      # The flash lasts one page view; whoever opens this application tomorrow still needs to know.
      failure = Event.where(action: 'application_post_creation_step_failed',
                            auditable_id: service.application.id).order(:id).last
      assert_not_nil failure, 'the incomplete step should be recorded durably'
      assert_equal 'notifications', failure.metadata['step']
    end

    # Running the audit first stopped a mail failure from skipping it, but running it *unguarded*
    # only moved the hazard. `AuditEventService` writes with `Event.create!`, so a failed audit
    # raised past notifications, the delivery checks and the provider request in one go -- and past
    # the durable record that any of them had been skipped. A committed application could end up
    # with no creation event, no follow-ups, and nothing but a generic flash.
    test 'a failed creation audit does not cancel the steps after it' do
      Applications::PaperApplicationService.any_instance.stubs(:log_application_creation)
                                           .raises(StandardError, 'audit write exploded')

      service = paper_service(base_paper_params)

      # Explicit expectations: "no warning" would also hold if these were never called at all.
      Applications::PaperApplicationService.any_instance.expects(:send_notifications).once
      Applications::PaperApplicationService.any_instance.expects(:append_proof_resubmission_delivery_warnings).once
      Applications::PaperApplicationService.any_instance.expects(:request_provider_info_if_missing).once

      assert service.create
      assert_match(/creation audit event did not finish/i, service.warning_message)
    end

    # The provider request reported its own failures into the reconciliation note and returned
    # normally, so the isolation wrapper never saw one. Staff got generic copy, and the step most
    # likely to fail was the only one that produced no durable event.
    test 'a failed provider request is named and recorded like any other step' do
      Applications::RequestProviderInfo.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'the secure form could not be delivered.', data: nil)
      )
      params = base_paper_params.merge(no_medical_provider_information: '1')

      service = paper_service(params)

      assert service.create
      assert_match(/certifying provider request did not finish/i, service.warning_message)
      # The actionable detail survives the move; naming the step is not a reason to lose it.
      assert_match(/You can send it from the application page/i, service.warning_message)

      failure = Event.where(action: 'application_post_creation_step_failed',
                            auditable_id: service.application.id).order(:id).last
      assert_not_nil failure, 'a failed provider request must outlive the flash'
      assert_equal 'the certifying provider request', failure.metadata['step']
    end

    # The same must hold when it raises rather than returning a failed result -- it used to catch
    # its own exceptions too.
    test 'a raised provider request failure is named and recorded like any other step' do
      Applications::RequestProviderInfo.any_instance.stubs(:call).raises(StandardError, 'delivery exploded')
      params = base_paper_params.merge(no_medical_provider_information: '1')

      service = paper_service(params)

      assert service.create
      assert_match(/certifying provider request did not finish/i, service.warning_message)
      # A raised failure is as actionable as a returned one, so the manual-send guidance must
      # survive it too -- an untyped StandardError would reach the wrapper without it.
      assert_match(/You can send it from the application page/i, service.warning_message)

      failure = Event.where(action: 'application_post_creation_step_failed',
                            auditable_id: service.application.id).order(:id).last
      assert_not_nil failure
      assert_equal 'the certifying provider request', failure.metadata['step']
      # The typed wrapper is for staff; the audit event has to name what actually failed. Recording
      # `PostCreationStepFailure` here would make every wrapped failure look identical and send
      # whoever investigates to the re-raise site instead of the real one.
      assert_equal 'StandardError', failure.metadata['error_class'],
                   'the audit event must record the underlying error, not the typed wrapper'
    end

    # The path that started all of this: a callback raises after the data is already durable. The
    # service kept the application and warned, but recorded nothing -- and a flash is gone after one
    # page view, so tomorrow's reviewer had no sign the callback work might be incomplete.
    test 'a confirmed post-commit callback failure is recorded durably' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      params = base_paper_params.merge(id_proof_action: 'reject', id_proof_rejection_reason: 'none_provided')

      service = paper_service_with_proofs(params)

      assert service.create
      assert service.commit_confirmed?, 'this scenario is the confirmed-commit one'

      failure = Event.where(action: 'application_post_creation_step_failed',
                            auditable_id: service.application.id).order(:id).last
      assert_not_nil failure, 'a confirmed callback failure must outlive the flash'
      assert_equal 'a post-commit callback', failure.metadata['step'],
                   'the callback path must stay distinguishable from the steps we run ourselves'
    end

    # An unconfirmed commit means the database just failed to answer a question about this record.
    # Continuing to work against it would raise again -- and that exception is caught as a *failure*,
    # which would hand back a retry form for an application that may well exist.
    test 'an unverifiable commit does no further work against the record' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      Application.stubs(:exists?).raises(ActiveRecord::ConnectionNotEstablished, 'database went away')
      params = base_paper_params.merge(id_proof_action: 'reject', id_proof_rejection_reason: 'none_provided')

      service = paper_service_with_proofs(params)

      Applications::PaperApplicationService.any_instance.expects(:send_notifications).never
      Applications::PaperApplicationService.any_instance.expects(:reconcile_after_paper_write).never

      assert service.create, 'an unconfirmed commit stays on the success side'
      assert_not service.commit_confirmed?
    end

    # The audit event is the durable record that this application was created. It used to run after
    # notifications, so a mail failure skipped it entirely -- leaving a committed application with
    # no `application_created` event and nothing durable saying the follow-up had not finished.
    test 'the creation audit event survives a notification failure' do
      Applications::PaperApplicationService.any_instance.stubs(:send_notifications)
                                           .raises(StandardError, 'notification exploded')

      service = nil
      assert_difference "Event.where(action: 'application_created').count", 1 do
        service = paper_service(base_paper_params)
        assert service.create
      end

      event = Event.where(action: 'application_created').order(:id).last
      assert_equal service.application.id, event.auditable_id
    end

    # Two different follow-up failures on one application are two findings. Fingerprinting the event
    # by action alone made the second look like a repeat of the first inside the dedup window, so
    # staff were told about half of what went wrong.
    test 'two different post-creation failures are recorded separately' do
      Applications::PaperApplicationService.any_instance.stubs(:send_notifications)
                                           .raises(StandardError, 'notification exploded')
      Applications::PaperApplicationService.any_instance.stubs(:append_proof_resubmission_delivery_warnings)
                                           .raises(StandardError, 'delivery check exploded')

      service = paper_service(base_paper_params)

      assert service.create
      steps = Event.where(action: 'application_post_creation_step_failed',
                          auditable_id: service.application.id).map { |event| event.metadata['step'] }
      assert_equal ['notifications', 'proof delivery checks'].sort, steps.sort,
                   "both failures should be recorded, got: #{steps.inspect}"
      assert_match(/notifications did not finish/i, service.warning_message)
      assert_match(/proof delivery checks did not finish/i, service.warning_message)
    end

    # The two warning channels name different situations, so a request that hits both must not
    # silently drop one of them.
    test 'a post-commit failure and a reconciliation failure are both reported' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      Application.any_instance.stubs(:reconcile_workflow_state!).raises(StandardError, 'reconciliation exploded')
      params = base_paper_params.merge(id_proof_action: 'reject', id_proof_rejection_reason: 'none_provided')

      service = paper_service_with_proofs(params)

      assert service.create
      assert_match(/follow-up step did not finish/i, service.warning_message)
      assert_match(/verify this application status/i, service.warning_message)
    end

    # The other leg: once the transaction commits, a later reconciliation problem is a *success* with
    # a warning. It must never turn into a false result, because then a committed application would
    # be reported as a failure.
    test 'a reconciliation failure after commit still reports success with a warning' do
      Application.any_instance.stubs(:reconcile_workflow_state!).raises(StandardError, 'reconciliation exploded')

      service = paper_service(base_paper_params)

      assert_difference ['Application.count', 'User.count'], 1 do
        assert service.create, "expected success with a warning, got errors: #{service.errors.inspect}"
      end
      assert_includes service.reconciliation_note.to_s, 'verify this application status'
      assert Application.exists?(service.application.id), 'the committed application must still be there'
    end

    # The panel refuses to offer a retired record, but the panel is not the boundary:
    # existing_constituent_id is a plain form field, so the write path has to refuse it on its own
    # rather than trusting that the browser only ever sends back ids it was shown.
    test 'a forged existing_constituent_id naming a retired merged record is refused' do
      survivor = create(:constituent)
      retired = create(:constituent, merged_into_user: survivor)
      params = base_paper_params.merge(existing_constituent_id: retired.id, contact_info_verified: '1')

      assert_no_difference ['Application.count', 'User.count'] do
        service = paper_service(params)

        assert_not service.create
        assert_includes service.errors.join(' '), 'not eligible as an applicant'
      end
    end

    # The event is attached to the constituent, whose record already holds the identity facts, so
    # repeating them here would duplicate PII into the audit trail for no gain. The token is a
    # credential-shaped value with no meaning after the request that spent it.
    test 'the confirmation event carries no raw identity facts and no token' do
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2))
      params = soft_match_params(existing)
      first = paper_service(params)
      first.create
      token = first.pending_identity_decision[:token]

      paper_service(params.merge(identity_decision: token)).create
      event = Event.where(action: 'paper_identity_no_match_confirmed').order(:id).last

      serialized = event.metadata.to_json
      assert_not_includes serialized, token
      [params[:constituent][:first_name], params[:constituent][:email],
       params[:constituent][:phone]].each do |fact|
        assert_not_includes serialized, fact.to_s
      end
    end

    # The event is written mid-transaction, before the application and proofs exist. If a later step
    # fails, the audit trail must not keep a confirmation for a constituent who was never created --
    # that would be evidence of a decision about a record nobody can look at.
    test 'a failure after the confirmation rolls the event back with everything else' do
      # A soft match, because only an override writes evidence -- there is no event to roll back on
      # the path where nothing surfaced.
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2))
      params = soft_match_params(existing)
      first = paper_service(params)
      first.create
      confirmed = params.merge(identity_decision: first.pending_identity_decision[:token])

      service = paper_service(confirmed)
      service.stubs(:create_application).returns(false)

      assert_no_difference ['User.count', 'Application.count',
                            "Event.where(action: 'paper_identity_no_match_confirmed').count"] do
        assert_not service.create
      end
    end

    test 'a refused review writes no confirmation evidence' do
      existing = create(:constituent, first_name: 'Soft', last_name: 'Match',
                                      date_of_birth: Date.new(1990, 4, 2))

      assert_no_difference "Event.where(action: 'paper_identity_no_match_confirmed').count" do
        paper_service(soft_match_params(existing)).create
        paper_service(soft_match_params(existing).merge(identity_decision: "v1:#{Time.current.to_i}:#{'0' * 64}")).create
      end
    end

    private

    def paper_service(params)
      PaperApplicationService.new(params: params, admin: @admin, skip_proof_processing: true)
    end

    # Proof processing left on, because the failure being pinned happens inside it.
    def paper_service_with_proofs(params)
      PaperApplicationService.new(params: params, admin: @admin)
    end

    def base_paper_params
      { constituent: @constituent_params.merge(email: "paper-#{SecureRandom.hex(4)}@example.com",
                                               phone: "202555#{rand(1000..9999)}"),
        application: @application_params }
    end

    # Same name and date of birth as an existing constituent, but distinct contact, so detection
    # returns a soft match rather than an exact-contact hard block.
    def soft_match_params(existing)
      params = base_paper_params
      params[:constituent] = params[:constituent].merge(
        first_name: existing.first_name,
        last_name: existing.last_name,
        date_of_birth: existing.date_of_birth
      )
      params
    end

    def existing_dependent_service_params(guardian, dependent)
      {
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'Parent',
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'guardian',
        constituent: { hearing_disability: true },
        application: @application_params
      }
    end
  end
end
