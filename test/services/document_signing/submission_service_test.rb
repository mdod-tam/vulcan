# frozen_string_literal: true

require 'test_helper'

module DocumentSigning
  class SubmissionServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @application = create(:application, :in_progress,
                            medical_provider_email: 'doctor@example.com',
                            medical_provider_name: 'Dr. Jane Smith')

      # Mock DocuSeal API response
      @mock_submission = {
        'id' => 'sub_123456',
        'submitters' => [
          {
            'id' => 'submitter_789',
            'email' => 'doctor@example.com',
            'name' => 'Dr. Jane Smith'
          }
        ]
      }
    end

    test 'successfully creates document signing submission' do
      # Mock the DocuSeal API call
      DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      assert_difference -> { @application.reload.document_signing_request_count }, 1 do
        result = service.call
        assert result.success?
      end

      @application.reload
      assert_equal 'docuseal', @application.document_signing_service
      assert_equal 'sub_123456', @application.document_signing_submission_id
      assert_equal 'submitter_789', @application.document_signing_submitter_id
      assert_equal 'sent', @application.document_signing_status
      assert_not_nil @application.document_signing_requested_at
      assert_operator @application.document_signing_requested_at, :<=, Time.current
      assert_equal 1, @application.document_signing_request_count

      # Medical certification tracking should also be updated
      assert_equal 'requested', @application.medical_certification_status
      assert_not_nil @application.medical_certification_requested_at
      assert_equal 1, @application.medical_certification_request_count
    end

    test 'prevents duplicate requests within 30 seconds' do
      @application.update!(
        document_signing_requested_at: 15.seconds.ago,
        document_signing_request_count: 1
      )

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      assert_no_difference -> { @application.reload.document_signing_request_count } do
        result = service.call
        assert result.failure?
        assert_includes result.message, 'Request sent too recently'
      end
    end

    test 'allows requests after 30 seconds cooldown' do
      @application.update!(
        document_signing_requested_at: 31.seconds.ago,
        document_signing_request_count: 1
      )

      DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      assert_difference -> { @application.reload.document_signing_request_count }, 1 do
        result = service.call
        assert result.success?
      end
    end

    test 'fails without medical provider email' do
      @application.update_columns(medical_provider_email: nil)

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      result = service.call
      assert result.failure?
      assert_equal 'Medical provider email is required', result.message
    end

    test 'fails without medical provider name' do
      @application.update_columns(medical_provider_name: nil)

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      result = service.call
      assert result.failure?
      assert_equal 'Medical provider name is required', result.message
    end

    test 'fails without actor' do
      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: nil
      )

      result = service.call
      assert result.failure?
      assert_equal 'Actor is required', result.message
    end

    test 'handles DocuSeal API errors gracefully' do
      DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).raises(StandardError, 'API Error')

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      result = service.call
      assert result.failure?
      assert_includes result.message, 'Failed to create document signing request'
    end

    test 'creates audit event on successful submission' do
      DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      assert_difference 'Event.count', 1 do
        result = service.call
        assert result.success?
      end

      event = Event.last
      assert_equal 'document_signing_request_sent', event.action
      assert_equal @admin, event.user
      assert_equal @application, event.auditable
      assert_equal 'docuseal', event.metadata['document_signing_service']
      assert_equal 'sub_123456', event.metadata['document_signing_submission_id']
    end

    test 'supports different service types' do
      DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin,
        service: 'alternative_service'
      )

      result = service.call
      assert result.success?

      @application.reload
      assert_equal 'alternative_service', @application.document_signing_service
    end

    test 'increments counters atomically' do
      DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      # Ensure both counters increment together
      original_doc_count = @application.document_signing_request_count
      original_med_count = @application.medical_certification_request_count

      result = service.call
      assert result.success?

      @application.reload
      assert_equal original_doc_count + 1, @application.document_signing_request_count
      assert_equal original_med_count + 1, @application.medical_certification_request_count
    end
  end
end
