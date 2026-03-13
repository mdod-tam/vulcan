# frozen_string_literal: true

require 'test_helper'

class MedicalCertificationAttachmentServiceTest < ActiveSupport::TestCase
  include ActiveStorageHelper
  include ActionDispatch::TestProcess::FixtureFile

  setup do
    clear_active_storage # Clear storage first
    # Use FactoryBot instead of fixtures
    @application = create(:application, status: :in_progress)
    @admin = create(:admin)
    @test_file = fixture_file_upload('medical_certification_valid.pdf', 'application/pdf')
  end

  test 'attaches medical certification with ActionDispatch::Http::UploadedFile' do
    assert_difference 'ActiveStorage::Attachment.count' do
      result = MedicalCertificationAttachmentService.attach_certification(
        application: @application,
        blob_or_file: @test_file,
        status: :approved,
        admin: @admin,
        submission_method: :admin_upload
      )

      assert result[:success], 'Direct file upload should succeed'
      assert @application.reload.medical_certification.attached?
      assert_equal 'approved', @application.medical_certification_status # Corrected assertion
    end
  end

  test 'handles failed blob creation gracefully with fallback' do
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with(regexp_matches(/Failed to create blob from uploaded file: Simulated blob creation failure/)).once

    # Mock Blob.create_and_upload! to simulate a failure
    ActiveStorage::Blob.stub :create_and_upload!, ->(*_args) { raise StandardError, 'Simulated blob creation failure' } do
      assert_difference 'ActiveStorage::Attachment.count' do
        result = MedicalCertificationAttachmentService.attach_certification(
          application: @application,
          blob_or_file: @test_file,
          status: :approved, # Corrected status enum value
          admin: @admin,
          submission_method: :admin_upload
        )

        assert result[:success], 'Should succeed with fallback'
        assert @application.reload.medical_certification.attached?
      end
    end
  end

  test 'properly handles signed_id strings' do
    # First create a blob to get its signed_id
    blob = create_dummy_blob
    signed_id = blob.signed_id

    # Then use the signed_id for attachment
    assert_difference 'ActiveStorage::Attachment.count' do
      result = MedicalCertificationAttachmentService.attach_certification(
        application: @application,
        blob_or_file: signed_id,
        status: :approved, # Corrected status enum value
        admin: @admin,
        submission_method: :admin_upload
      )

      assert result[:success], 'Signed ID should work correctly'
      assert @application.reload.medical_certification.attached?
    end
  end

  test 'rejects medical certification without requiring an attachment' do
    assert_no_difference 'ActiveStorage::Attachment.count' do
      result = MedicalCertificationAttachmentService.reject_certification(
        application: @application,
        admin: @admin,
        reason: 'missing_signature',
        notes: 'Test rejection note',
        submission_method: :admin_review
      )

      assert result[:success], 'Rejection should succeed'
      assert_equal 'rejected', @application.reload.medical_certification_status
      assert_equal 'missing_signature', @application.medical_certification_rejection_reason
    end
  end

  private

  def create_dummy_blob
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('dummy content'),
      filename: 'dummy.txt',
      content_type: 'text/plain'
    )
  end
end
