# frozen_string_literal: true

class CleanupDocumentScansJob < ApplicationJob
  RETENTION = 7.days
  queue_as :low

  def perform
    DocumentScan.where.not(status: 'pending').where(created_at: ...RETENTION.ago).find_each do |scan|
      blob = scan.blob
      blob.with_lock do
        scan.with_lock do
          unless scan.pending? || blob.attachments.exists?
            # The blob foreign key removes its scan in the same transaction.
            blob.destroy!
            ActiveRecord::Base.current_transaction.after_commit { blob.delete }
          end
        end
      end
    rescue ActiveRecord::RecordNotFound, ActiveRecord::InvalidForeignKey
      # Intake, a retained review, or another worker won the deletion boundary.
      next
    end
  end
end
