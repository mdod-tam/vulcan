# frozen_string_literal: true

require 'test_helper'

module DocumentSigning
  class SubmissionServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      ensure_system_audit_actor!
      @constituent = create(:constituent, :with_address_and_phone)
      @application = create(:application, :in_progress,
                            user: @constituent,
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

      # Disability certification tracking should also be updated
      assert_equal 'requested', @application.disability_certification_status
      assert_not_nil @application.disability_certification_requested_at
      assert_equal 1, @application.disability_certification_request_count
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
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with do |message|
        message.include?('DocumentSigning::SubmissionService: StandardError') &&
          message.include?('application_id') && message.include?(@application.id.to_s) && message.exclude?('API Error')
      end.once

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      result = service.call
      assert result.failure?
      assert_equal 'Failed to create document signing request.', result.message
    end

    test 'creates audit event on successful submission' do
      DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      assert_difference -> { Event.where(action: 'document_signing_request_sent').count }, 1 do
        result = service.call
        assert result.success?
      end

      event = Event.find_by!(action: 'document_signing_request_sent')
      assert_equal @admin, event.user
      assert_equal @application, event.auditable
      assert_equal 'docuseal', event.metadata['document_signing_service']
      assert_equal 'sub_123456', event.metadata['document_signing_submission_id']
    end

    test 'records the requested certification status in the status history and audit log' do
      DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

      result = DocumentSigning::SubmissionService.new(application: @application, actor: @admin).call

      assert result.success?
      change = @application.status_changes.disability_certification.sole
      assert_equal %w[not_requested requested], [change.from_status, change.to_status]
      assert_equal @admin, change.user
      assert_equal ['document_signing', 'Dr. Jane Smith'], change.metadata.values_at('submission_method', 'provider_name')
      event = Event.find_by!(action: 'disability_certification_requested', auditable: @application)
      assert_equal %w[not_requested requested document_signing],
                   event.metadata.values_at('old_status', 'new_status', 'submission_method')
    end

    test 'preserves open secure certification upload forms when sending DocuSeal request' do
      secure_request_form = create(:certification_upload_form, application: @application)
      DocumentSigning::SubmissionService.any_instance.stubs(:create_submission!).returns(@mock_submission)

      result = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      ).call

      assert result.success?
      assert_predicate secure_request_form.reload, :active?
      assert_predicate secure_request_form, :status_sent?
      assert_nil secure_request_form.revoked_at
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

      original_doc_count = @application.document_signing_request_count
      original_med_count = @application.disability_certification_request_count

      result = service.call
      assert result.success?

      @application.reload
      assert_equal original_doc_count + 1, @application.document_signing_request_count
      assert_equal original_med_count + 1, @application.disability_certification_request_count
    end

    test 'creates a custom signer email message with applicant context' do
      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      Docuseal.expects(:create_submission).with do |payload|
        assert_equal "Disability Certification - #{@application.user.full_name} (Application #{@application.id})", payload[:name]
        assert_equal "Disability Certification Request for #{@application.user.full_name}", payload.dig(:message, :subject)
        assert_includes payload.dig(:message, :body), @application.user.full_name
        assert_includes payload.dig(:message, :body), @application.user.date_of_birth.strftime('%m/%d/%Y')
        assert_includes payload.dig(:message, :body), @application.user.phone
        assert_includes payload.dig(:message, :body), @application.user.email
        assert_includes payload.dig(:message, :body), '{{submitter.link}}'
        true
      end.returns(@mock_submission)

      service.send(:create_submission!)
    end

    test 'localizes the custom signer email message for spanish applicants' do
      @application.user.update!(locale: 'es')

      service = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: @admin
      )

      Docuseal.expects(:create_submission).with do |payload|
        assert_equal "Certificación de discapacidad - #{@application.user.full_name} (Solicitud #{@application.id})", payload[:name]
        assert_equal "Solicitud de certificación de discapacidad para #{@application.user.full_name}", payload.dig(:message, :subject)
        assert_includes payload.dig(:message, :body), 'Información del solicitante'
        assert_includes payload.dig(:message, :body), '{{submitter.link}}'
        true
      end.returns(@mock_submission)

      service.send(:create_submission!)
    end

    test 'with email off no DocuSeal submission is made and nothing is marked sent' do
      EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: false, actor: @admin, operation_id: 'op-1')
      ::Docuseal.expects(:create_submission).never

      result = DocumentSigning::SubmissionService.new(application: @application, actor: @admin).call

      assert_not result.success?
      assert result.data[:delivery_suppressed]
      @application.reload
      assert_nil @application.document_signing_requested_at
      assert_nil @application.document_signing_submission_id
      assert @application.disability_certification_status_not_requested?
      assert_equal 0, @application.document_signing_request_count.to_i
      assert_equal 0, @application.disability_certification_request_count.to_i
      assert Event.exists?(action: EmailDelivery::Outcome::SUPPRESSED)
      assert_not Event.exists?(action: 'document_signing_request_sent', auditable: @application)
    end
  end
end
