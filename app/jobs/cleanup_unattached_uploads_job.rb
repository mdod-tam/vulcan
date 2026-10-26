# frozen_string_literal: true

# Unattached documents stay available for the upload retry window.
class CleanupUnattachedUploadsJob < ApplicationJob
  queue_as :low

  def perform
    candidates = ActiveStorage::Blob.unattached.where(created_at: ...DocumentScan::RETENTION.ago)
                                    .where.not(id: DocumentScan.pending.select(:blob_id))
    candidates.find_each do |blob|
      blob.with_lock do
        scan = DocumentScan.lock.find_by(blob_id: blob.id)
        unless scan&.pending? || blob.attachments.exists?
          # The blob foreign key removes scan history in the same transaction.
          blob.destroy!
          ActiveRecord::Base.current_transaction.after_commit { blob.delete }
        end
      end
    rescue ActiveRecord::RecordNotFound, ActiveRecord::InvalidForeignKey, ActiveRecord::Deadlocked
      # Intake, a retained review, or another worker won this candidate.
      next
    end
  end
end
