# frozen_string_literal: true

require 'test_helper'

class CleanupUnattachedUploadsJobTest < ActiveSupport::TestCase
  test 'preserves unresolved scans even when their unattached blob is old' do
    pending = upload
    pending.update!(created_at: 8.days.ago)
    user = create(:constituent)
    mark_document_clean!(pending, user: user)
    scan = DocumentScan.find_by!(blob: pending)
    scan.update!(status: :pending, created_at: pending.created_at)

    CleanupUnattachedUploadsJob.perform_now

    assert ActiveStorage::Blob.exists?(pending.id)
    assert DocumentScan.exists?(scan.id)
    assert pending.service.exist?(pending.key)
  end

  test 'purges abandoned uploads but preserves recent retries and attached documents' do
    old = upload
    recent = upload
    attached = upload
    application = create(:application)
    application.income_proof.attach(attached)
    old.update!(created_at: 8.days.ago)
    attached.update!(created_at: 8.days.ago)

    CleanupUnattachedUploadsJob.perform_now

    assert_not ActiveStorage::Blob.exists?(old.id)
    assert ActiveStorage::Blob.exists?(recent.id)
    assert application.reload.income_proof.attached?
    assert attached.service.exist?(attached.key)
  end

  private

  def upload
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new('proof'), filename: 'proof.pdf', content_type: 'application/pdf')
  end
end
