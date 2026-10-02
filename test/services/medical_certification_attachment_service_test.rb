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

  test 'accept_submission applies one placement table to every submission channel' do
    cases = {
      not_requested: [nil, :primary, nil],
      requested: [nil, :primary, nil],
      received: [nil, :additional, 'certification_received'],
      approved: [nil, :additional, 'certification_approved'],
      rejected_then_requested: [1.day.ago, :primary, nil],
      requested_then_rejected: [3.days.ago, :additional, 'request_predates_rejection']
    }

    %i[secure_form docuseal].each do |submission_method|
      cases.each do |label, (requested_at, placement, reason)|
        application = create(:application, status: :in_progress)
        status = label.to_s.start_with?('rejected', 'requested_then') ? :rejected : label
        application.update_columns(medical_certification_status: Application.medical_certification_statuses[status])
        if status == :rejected
          ApplicationStatusChange.create!(application: application, user: @admin, from_status: 'requested', to_status: 'rejected',
                                          change_type: 'medical_certification', changed_at: 2.days.ago)
        end
        blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('cert'), filename: 'cert.pdf', content_type: 'application/pdf')

        result = MedicalCertificationAttachmentService.accept_submission(
          application: application, blob: blob, submission_method: submission_method,
          requested_at: requested_at || 1.hour.ago, admin: @admin
        )

        message = "#{submission_method} #{label}"
        assert result[:success], message
        assert_equal placement, result[:placement], message
        assert_equal reason, result[:retention_reason], message
        expected_status = placement == :primary ? 'received' : status.to_s
        assert_equal expected_status, application.reload.medical_certification_status, message
      end
    end
  end

  test 'attaching a direct upload does not log upload references or file names' do
    blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture('medical_certification_valid.pdf').open,
                                                  filename: 'private-proof.pdf', content_type: 'application/pdf')
    messages = []
    Rails.logger.stub(:info, ->(message = nil, &block) { messages << (message || block&.call) }) do
      MedicalCertificationAttachmentService.attach_certification(
        application: @application, blob_or_file: blob.signed_id, status: :approved,
        admin: @admin, submission_method: :admin_upload
      )
    end
    [blob.signed_id, blob.key, blob.filename.to_s].each do |private_value|
      assert_not_includes messages.join, private_value
    end
  end

  test 'attaches medical certification with ActionDispatch::Http::UploadedFile' do
    assert_no_enqueued_jobs only: EmailDelivery::MailDeliveryJob do
      assert_difference 'ActiveStorage::Attachment.count' do
        assert_difference -> { Notification.where(action: 'medical_certification_approved').count }, 1 do
          assert_difference -> { Event.where(action: 'medical_certification_status_changed', auditable: @application).count }, 1 do
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
      end
    end

    notification = Notification.where(action: 'medical_certification_approved').last
    assert_equal @application.user, notification.recipient
    assert_equal @application, notification.notifiable
    assert_nil notification.delivery_status
    assert_nil notification.metadata&.dig('delivery_error', 'message')

    event = Event.where(action: 'medical_certification_status_changed', auditable: @application).last
    assert_equal 'approved', event.metadata['new_status']
  end

  test 'medical certification approval notification remains record-only when delivery is requested' do
    assert_no_enqueued_jobs only: EmailDelivery::MailDeliveryJob do
      notification = NotificationService.create_and_deliver!(
        type: 'medical_certification_approved',
        recipient: @application.user,
        actor: @admin,
        notifiable: @application,
        channel: :email
      )

      assert_equal 'none', notification.reload.metadata['actual_delivery_channel']
      assert_equal 'no_email_action', notification.metadata['delivery_route_reason']
    end
  end

  test 'a staff upload rechecks eligibility under the lock a provider submission takes' do
    @application.update!(medical_certification_status: :requested)
    stale = Application.find(@application.id)
    # A provider submission commits after the staff request read the application as requested
    provider_blob = create_dummy_blob
    MedicalCertificationAttachmentService.accept_submission(
      application: Application.find(@application.id), blob: provider_blob, submission_method: :secure_form,
      requested_at: 1.hour.ago, admin: @admin
    )
    assert_equal 'requested', stale.medical_certification_status

    assert_no_difference 'ActiveStorage::Attachment.count' do
      assert_raises(MedicalCertificationAttachmentService::StaffUploadNotAllowed) do
        MedicalCertificationAttachmentService.attach_certification(
          application: stale, blob_or_file: @test_file, status: :approved,
          admin: @admin, submission_method: :admin_upload
        )
      end
    end
    @application.reload
    assert_equal 'received', @application.medical_certification_status
    assert_equal provider_blob, @application.medical_certification.blob
  end

  test 'staff upload returns once a certification is rejected' do
    @application.update_columns(medical_certification_status: Application.medical_certification_statuses[:rejected])

    result = MedicalCertificationAttachmentService.attach_certification(
      application: @application, blob_or_file: @test_file, status: :approved,
      admin: @admin, submission_method: :admin_upload
    )

    assert result[:success]
    assert_equal 'approved', @application.reload.medical_certification_status
  end

  test 'a storage failure attaches nothing instead of falling back to the raw upload' do
    ActiveStorage::Blob.stub :create_and_upload!, ->(**) { raise StandardError, 'Simulated blob creation failure' } do
      assert_no_difference 'ActiveStorage::Attachment.count' do
        assert_raises(StandardError) do
          MedicalCertificationAttachmentService.attach_certification(
            application: @application, blob_or_file: @test_file, status: :approved,
            admin: @admin, submission_method: :admin_upload
          )
        end
      end
    end
    assert_not_predicate @application.reload.medical_certification, :attached?
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
    starting_rejections = @application.total_rejections

    assert_no_difference 'ActiveStorage::Attachment.count' do
      assert_no_enqueued_jobs only: EmailDelivery::MailDeliveryJob do
        assert_difference 'Notification.count', 1 do
          result = MedicalCertificationAttachmentService.reject_certification(
            application: @application,
            admin: @admin,
            reason: 'missing_signature',
            notes: 'Test rejection note',
            submission_method: :admin_review
          )

          assert result[:success], 'Rejection should succeed'
        end
      end

      @application.reload
      assert_equal 'rejected', @application.medical_certification_status
      assert_equal 'missing_signature', @application.medical_certification_rejection_reason
      assert_equal starting_rejections, @application.total_rejections
      review = @application.proof_reviews.find_by!(proof_type: :medical_certification, status: :rejected)
      assert_equal 'missing_signature', review.rejection_reason
      assert_nil review.rejection_reason_code

      notification = Notification.order(:created_at).last
      assert_equal 'medical_certification_rejected', notification.action
      assert_equal @application.user, notification.recipient
      assert_equal @application, notification.notifiable
      assert_equal 'missing_signature', notification.metadata['rejection_reason']
      assert_not notification.metadata.key?('reason')
      assert_nil notification.delivery_status
      assert_nil notification.metadata&.dig('delivery_error', 'message')
    end
  end

  test 'clears stored rejection reason code when rejecting with free text' do
    first_result = MedicalCertificationAttachmentService.reject_certification(
      application: @application,
      admin: @admin,
      reason: 'Initial coded rejection reason',
      reason_code: 'missing_signature',
      submission_method: :admin_review
    )

    assert first_result[:success], 'Initial coded rejection should succeed'
    @application.reload
    first_review = @application.proof_reviews.find_by!(proof_type: :medical_certification, status: :rejected)
    assert_equal 'missing_signature', @application.medical_certification_rejection_reason_code
    assert_equal 'missing_signature', first_review.rejection_reason_code

    second_result = MedicalCertificationAttachmentService.reject_certification(
      application: @application,
      admin: @admin,
      reason: 'Custom follow-up rejection text',
      reason_code: '',
      submission_method: :admin_review
    )

    assert second_result[:success], 'Follow-up free-text rejection should succeed'
    @application.reload
    second_review = @application.proof_reviews.find_by!(proof_type: :medical_certification, status: :rejected)
    assert_equal 'Custom follow-up rejection text', @application.medical_certification_rejection_reason
    assert_nil @application.medical_certification_rejection_reason_code
    assert_equal 'Custom follow-up rejection text', second_review.rejection_reason
    assert_nil second_review.rejection_reason_code
  end

  private

  def create_dummy_blob
    ActiveStorage::Blob.create_and_upload!(
      io: file_fixture('medical_certification_valid.pdf').open,
      filename: 'certification.pdf',
      content_type: 'application/pdf'
    )
  end
end
