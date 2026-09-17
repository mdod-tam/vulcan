# frozen_string_literal: true

# A completed direct upload remains available for a week of intake retries.
class CleanupUnattachedUploadsJob < ApplicationJob
  RETENTION = 7.days
  queue_as :low

  def perform
    ActiveStorage::Blob.unattached.where(created_at: ...RETENTION.ago).find_each do |blob|
      blob.with_lock do
        blob.purge unless blob.attachments.exists?
      end
    end
  end
end
