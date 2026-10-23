# frozen_string_literal: true

require 'test_helper'

class DocumentScanMaintenanceTest < ActiveSupport::TestCase
  setup do
    @user = create(:constituent)
  end

  test 'recovery resumes expired leases fails abandoned allocation and retries an unfinished continuation' do
    freeze_time do
      expired = scan(lease_token: SecureRandom.uuid, lease_expires_at: 1.second.ago, next_attempt_at: nil)
      unready = scan(next_attempt_at: nil, created_at: 1.hour.ago)
      active = scan(lease_token: SecureRandom.uuid, lease_expires_at: 1.minute.from_now, next_attempt_at: nil)
      continuation = scan(status: 'clean', user: nil, continuation: 'docuseal')
      DocumentScanJob.expects(:perform_later).with(expired.id)
      DocumentSigning::AcceptScannedDocumentJob.expects(:perform_later).with(continuation.id)

      RecoverDocumentScansJob.perform_now

      assert unready.reload.failed?
      assert_equal 'scan_unresolved', unready.last_error_code
      assert active.reload.pending?
      assert expired.reload.pending?
    end
  end

  test 'cleanup removes old unattached snapshots and preserves attached or recent documents' do
    abandoned = scan(status: 'failed', created_at: 8.days.ago)
    recent = scan(status: 'blocked')
    attached = scan(status: 'clean', created_at: 8.days.ago)
    application = create(:application)
    application.income_proof.attach(attached.blob)

    CleanupDocumentScansJob.perform_now

    assert_not DocumentScan.exists?(abandoned.id)
    assert DocumentScan.exists?(recent.id)
    assert DocumentScan.exists?(attached.id)
    assert application.reload.income_proof.attached?
    assert attached.blob.service.exist?(attached.blob.key)
  end

  private

  def scan(**attributes)
    bytes = 'private snapshot'
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: 'proof.pdf', content_type: 'application/pdf')
    DocumentScan.create!({ blob: blob, user: @user, purpose: 'proof', slot: 'income_proof', sha256: Digest::SHA256.hexdigest(bytes),
                           next_attempt_at: Time.current }.merge(attributes))
  end
end
