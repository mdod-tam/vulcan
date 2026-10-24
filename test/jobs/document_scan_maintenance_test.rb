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
      blocked = scan(status: 'blocked', user: nil, continuation: 'docuseal')
      failed = scan(status: 'failed', user: nil, continuation: 'docuseal')
      handled = scan(status: 'failed', user: nil, continuation: 'docuseal', continued_at: Time.current)
      DocumentScanJob.expects(:perform_later).with(expired.id)
      DocumentSigning::AcceptScannedDocumentJob.expects(:perform_later).with(continuation.id)
      DocumentSigning::AcceptScannedDocumentJob.expects(:perform_later).with(blocked.id)
      DocumentSigning::AcceptScannedDocumentJob.expects(:perform_later).with(failed.id)
      DocumentSigning::AcceptScannedDocumentJob.expects(:perform_later).with(handled.id).never

      RecoverDocumentScansJob.perform_now

      assert unready.reload.failed?
      assert_equal 'scan_unresolved', unready.last_error_code
      assert active.reload.pending?
      assert expired.reload.pending?
    end
  end

  test 'cleanup removes old unattached snapshots and preserves attached or recent documents' do
    abandoned = scan(status: 'failed', created_at: 8.days.ago)
    blocked = scan(status: 'blocked', created_at: 8.days.ago)
    clean = scan(status: 'clean', created_at: 8.days.ago)
    pending = scan(created_at: 8.days.ago)
    recent = scan(status: 'blocked')
    attached = scan(status: 'clean', created_at: 8.days.ago)
    application = create(:application)
    application.income_proof.attach(attached.blob)

    CleanupUnattachedUploadsJob.perform_now

    assert_not DocumentScan.exists?(abandoned.id)
    [blocked, clean].each do |expired|
      assert_not DocumentScan.exists?(expired.id)
      assert_not ActiveStorage::Blob.exists?(expired.blob_id)
    end
    assert DocumentScan.exists?(pending.id)
    assert DocumentScan.exists?(recent.id)
    assert DocumentScan.exists?(attached.id)
    assert application.reload.income_proof.attached?
    assert attached.blob.service.exist?(attached.blob.key)
  end

  test 'cleanup preserves scan clearance when a retained W9 review prevents blob deletion' do
    vendor = create(:vendor)
    retained = scan(status: 'clean', user: vendor, purpose: 'w9', slot: 'w9_form', created_at: 8.days.ago)
    review = create(:w9_review, vendor: vendor, reviewed_blob: retained.blob)
    abandoned = scan(status: 'failed', created_at: 8.days.ago)

    CleanupUnattachedUploadsJob.perform_now

    assert DocumentScan.exists?(retained.id)
    assert DocumentScan.cleared?(review.reload.reviewed_blob)
    assert retained.blob.service.exist?(retained.blob.key)
    assert_not DocumentScan.exists?(abandoned.id)
  end

  private

  def scan(**attributes)
    bytes = 'private snapshot'
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: 'proof.pdf', content_type: 'application/pdf')
    blob.update!(created_at: attributes[:created_at]) if attributes[:created_at]
    DocumentScan.create!({ blob: blob, user: @user, purpose: 'proof', slot: 'income_proof', sha256: Digest::SHA256.hexdigest(bytes),
                           next_attempt_at: Time.current }.merge(attributes))
  end
end
