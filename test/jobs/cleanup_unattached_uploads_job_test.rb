# frozen_string_literal: true

require 'test_helper'

class CleanupUnattachedUploadsJobTest < ActiveSupport::TestCase
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
