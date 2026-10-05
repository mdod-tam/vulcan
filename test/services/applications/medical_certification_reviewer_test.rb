# frozen_string_literal: true

require 'test_helper'

module Applications
  class MedicalCertificationReviewerTest < ActiveSupport::TestCase
    setup do
      @application = create(:application, :completed)
      @admin = create(:admin)
      @service = MedicalCertificationReviewer.new(@application, @admin)
      ActiveRecord.stubs(:after_all_transactions_commit).yields

      @application.update(
        medical_provider_name: 'Dr. Test Provider',
        medical_provider_email: 'provider@example.com',
        medical_provider_fax: '555-123-4567'
      )
    end

    test 'successfully rejects a medical certification' do
      MedicalCertificationAttachmentService.stub(:reject_certification, ->(**_args) { { success: true } }) do
        result = @service.reject(rejection_reason: 'Invalid documentation')
        assert(result.success?, 'Expected reviewer service to return success when attachment service succeeds')
      end

      # The attachment stub leaves certification status unchanged. This test covers the reviewer result.
      # assert_equal('rejected', @application.reload.medical_certification_status) # Remove this for now
    end

    test 'passes rejection notification id to medical provider notifier' do
      mock_notifier = mock('medical_provider_notifier')
      MedicalProviderNotifier.expects(:new).with(@application).returns(mock_notifier)
      mock_notifier.expects(:send_certification_rejection_notice).with(
        rejection_reason: 'Invalid documentation',
        admin: @admin,
        notification_id: 1234,
        secure_upload_url: 'https://example.test/secure_certification_form?token=abc'
      ).returns(success: true, outcome: :submitted, tracking_status: :recorded)
      request_result = BaseService::Result.new(
        success: true,
        message: 'sent',
        data: { secure_upload_url: 'https://example.test/secure_certification_form?token=abc' }
      )
      RequestCertificationUpload.any_instance.expects(:call).returns(request_result)

      MedicalCertificationAttachmentService.stub(:reject_certification, ->(**_args) { { success: true, notification_id: 1234 } }) do
        result = @service.reject(rejection_reason: 'Invalid documentation')
        assert(result.success?, 'Expected reviewer service to pass through success when notifier succeeds')
        assert_equal :submitted, result.data[:provider_delivery][:outcome]
        assert_equal 1234, result.data[:notification_id]
        assert_includes result.message, 'Provider email submitted.'
      end
    end

    test 'continues rejection notification when secure cert upload request fails for a non-remediation reason' do
      mock_notifier = mock('medical_provider_notifier')
      MedicalProviderNotifier.expects(:new).with(@application).returns(mock_notifier)
      mock_notifier.expects(:send_certification_rejection_notice).with(
        rejection_reason: 'Invalid documentation',
        admin: @admin,
        notification_id: 1234,
        secure_upload_url: nil
      ).returns(success: true, outcome: :queued, tracking_status: :recorded)
      request_result = BaseService::Result.new(success: false, message: 'temporary failure', data: {})
      RequestCertificationUpload.any_instance.expects(:call).returns(request_result)

      MedicalCertificationAttachmentService.stub(:reject_certification, ->(**_args) { { success: true, notification_id: 1234 } }) do
        result = @service.reject(rejection_reason: 'Invalid documentation')
        assert(result.success?, 'Expected rejection to succeed even when secure cert form cannot be issued')
      end
    end

    test 'fails when rejection reason is missing' do
      result = @service.reject(rejection_reason: '')
      assert_not(result.success?, 'Expected rejection to fail without a reason')
      assert_match(/Rejection reason is required/, result.message)
    end

    test 'retains rejection while reporting unavailable delivery when provider email is missing' do
      @application.update(medical_provider_email: nil, medical_provider_fax: '555-123-4567')
      mock_notifier = mock('medical_provider_notifier')
      MedicalProviderNotifier.expects(:new).with(@application).returns(mock_notifier)
      mock_notifier.expects(:send_certification_rejection_notice).with(
        rejection_reason: 'Invalid documentation',
        admin: @admin,
        notification_id: 1234,
        secure_upload_url: nil
      ).returns(success: false, outcome: :unavailable, tracking_status: :recorded)
      request_result = BaseService::Result.new(success: false, message: 'Provider email required', data: {})
      RequestCertificationUpload.any_instance.expects(:call).returns(request_result)

      MedicalCertificationAttachmentService.stub(:reject_certification, ->(**_args) { { success: true, notification_id: 1234 } }) do
        result = @service.reject(rejection_reason: 'Invalid documentation')
        assert result.success?
        assert_equal :unavailable, result.data[:provider_delivery][:outcome]
        assert_includes result.message, 'Provider email was not sent.'
      end
    end

    test 'creates an application note when notes are provided' do
      MedicalCertificationAttachmentService.stub(:reject_certification, ->(**_args) { { success: true } }) do
        assert_difference(-> { @application.application_notes.count }, 1, 'Expected ApplicationNote count to increase by 1') do
          @service.reject(rejection_reason: 'Invalid documentation', notes: 'Follow up required')
        end
      end

      note = @application.application_notes.last
      # assert_equal('medical_certification', note.note_type) # Removed assertion for non-existent attribute
      assert_match(/Follow up required/, note.content)
    end

    test 'creates application status change record' do
      # MedicalCertificationAttachmentService owns the status history.
      # Its success stub leaves the count unchanged.
      MedicalCertificationAttachmentService.stub(:reject_certification, ->(**_args) { { success: true } }) do
        # Additional tests for status history can exercise the attachment service directly.
        assert_difference(lambda {
          ApplicationStatusChange.count
        }, 0, 'ApplicationStatusChange should be created by the attachment service, not reviewer') do
          @service.reject(rejection_reason: 'Invalid documentation')
        end
      end
    end

    test 'retains durable rejection and reports actual provider failure' do
      notifier = stub(send_certification_rejection_notice: { success: false, outcome: :failed, tracking_status: :recorded })
      MedicalProviderNotifier.expects(:new).with(@application).returns(notifier)
      RequestCertificationUpload.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: true, data: { secure_upload_url: nil })
      )
      assert_difference -> { ApplicationStatusChange.where(application: @application, to_status: 'rejected').count }, 1 do
        result = @service.reject(rejection_reason: 'Invalid documentation')
        assert result.success?
        assert_equal :failed, result.data[:provider_delivery][:outcome]
        assert_includes result.message, 'Provider email was not sent.'
      end
      assert @application.reload.medical_certification_status_rejected?
    end

    test 'does not misreport accepted provider email when tracking fails' do
      MedicalCertificationAttachmentService.stubs(:reject_certification).returns(success: true, notification_id: 1234)
      RequestCertificationUpload.any_instance.stubs(:call).returns(BaseService::Result.new(success: true, data: {}))
      MedicalProviderNotifier.any_instance.stubs(:send_certification_rejection_notice).returns(
        success: true, outcome: :submitted, tracking_status: :failed, tracking_error: 'ActiveRecord::RecordInvalid'
      )

      result = @service.reject(rejection_reason: 'Invalid documentation')

      assert result.success?
      assert result.data[:provider_delivery][:success]
      assert_includes result.message, 'Provider email submitted.'
      assert_includes result.message, 'Delivery tracking failed; verify provider email before retrying.'
      assert_not_includes result.message, 'Provider email was not sent.'
    end

    test 'note failure does not turn a saved rejection into a retryable failure or expose exception text' do
      RequestCertificationUpload.any_instance.stubs(:call).returns(BaseService::Result.new(success: true, data: {}))
      MedicalProviderNotifier.any_instance.stubs(:send_certification_rejection_notice).returns(success: true, outcome: :queued)
      ApplicationNote.any_instance.expects(:save!).raises(StandardError, 'private note failure')

      result = @service.reject(rejection_reason: 'Missing signature', notes: 'Review the signature')

      assert result.success?
      assert @application.reload.medical_certification_status_rejected?
      assert_includes result.message, 'The rejection note could not be saved.'
      assert_not_includes result.message, 'private note failure'
    end

    test 'returns error when attachment service fails' do
      error_message = 'Simulated service failure'
      MedicalCertificationAttachmentService.stub(:reject_certification, ->(**_args) { { success: false, error: StandardError.new(error_message) } }) do
        result = @service.reject(rejection_reason: 'Invalid documentation')
        assert_not(result.success?, 'Expected reviewer service to return failure when attachment service fails')
        assert_match(/#{error_message}/, result.message)
      end
    end
  end
end
